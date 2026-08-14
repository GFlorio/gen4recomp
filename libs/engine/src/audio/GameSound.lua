-- GameSound: the semantic audio facade field scripts receive as their
-- `audio` service. It wraps the real engine audio (AudioAssetProvider +
-- SequencePlayer + VoiceMixer) and owns the script-observable semantics:
-- BGM (play/stop/replace/current), effects (play/stop; waits follow the
-- HGSS IsSEPlaying model -- resolve the sequence's player and test that
-- player's playback state, never an individual host-source token), the
-- fanfare state machine (pause the BGM player, play through the fanfare
-- sequence's own player, hold a 15-tick post-play wait advanced on field
-- fixed ticks, then resume the paused BGM; the post-wait length is the u16
-- 0x0F that the HGSS PlayFanfare path sets), fixed-tick fades (a fade
-- command while a fade is active is skipped; no current BGM means the fade
-- never starts; a fade-out to target 0 stops the BGM but keeps the
-- current-music reference for a later fade-in; the fade timer is frozen
-- while a fanfare is active, per the HGSS DoSoundUpdateFrame trace), the
-- cry boundary (a reachable cry without a cry subsystem is an attributed
-- failure until the cry data path lands), and the save-stability predicate
-- (false while a fade, fanfare, cry, or playable effect transient is
-- active; ordinary continuous map BGM never blocks saving). All polls
-- return booleans, never nil. The only injectable boundaries are the cry
-- subsystem and the map-music resolver (the field-music policy owner);
-- everything else runs the real engine audio.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class GameSound
---@field private _provider AudioAssetProvider
---@field private _player SequencePlayer
---@field private _cry table?
---@field private _mapMusic fun(): integer|string|nil?
---@field private _currentMusic integer?
---@field private _currentEffect integer?
---@field private _effectPlayers table<integer, boolean>
---@field private _fanfare table?
---@field private _musicFade table?
---@field private _cryActive boolean
---@field new fun(opts: { provider: AudioAssetProvider, player: SequencePlayer, cry: table?, mapMusic: fun(): integer|string|nil? }): GameSound
---@field play fun(self: GameSound, idOrSymbol: integer|string)
---@field stop fun(self: GameSound, idOrSymbol: integer|string)
---@field isEffectPlaying fun(self: GameSound, idOrSymbol: integer|string): boolean
---@field currentEffect fun(self: GameSound): integer?
---@field playMusic fun(self: GameSound, idOrSymbol: integer|string)
---@field stopMusic fun(self: GameSound)
---@field currentMusic fun(self: GameSound): integer?
---@field playFanfare fun(self: GameSound, idOrSymbol: integer|string)
---@field isFanfarePlaying fun(self: GameSound): boolean
---@field playCry fun(self: GameSound, species: integer, form: integer)
---@field isCryFinished fun(self: GameSound): boolean
---@field fadeMusicOut fun(self: GameSound, spec: { target: integer, durationTicks: integer })
---@field fadeMusicIn fun(self: GameSound, spec: { durationTicks: integer })
---@field isMusicFadeActive fun(self: GameSound): boolean
---@field resetMusic fun(self: GameSound)
---@field temporaryMusic fun(self: GameSound, idOrSymbol: integer|string)
---@field updateFixed fun(self: GameSound)
---@field isSaveStable fun(self: GameSound): boolean
---@field render fun(self: GameSound, frames: integer): integer[]

local GameSound = {}
GameSound.__index = GameSound

-- The post-fanfare wait interval in field fixed ticks: HGSS PlayFanfare
-- sets a u16 timer to 0x0F and the fanfare stays "playing" until it counts
-- down after the fanfare player stops.
local FANFARE_POST_WAIT_TICKS = 15

---@param opts { provider: AudioAssetProvider, player: SequencePlayer, cry: table?, mapMusic: fun(): integer|string|nil? }
---@return GameSound
function GameSound.new(opts)
  assert(opts and opts.provider and opts.player, "GameSound requires a provider and a player")
  if opts.cry then
    assert(
      type(opts.cry.play) == "function" and type(opts.cry.isFinished) == "function",
      "cry subsystem requires play and isFinished"
    )
  end
  if opts.mapMusic then
    assert(type(opts.mapMusic) == "function", "mapMusic resolver must be callable")
  end
  return setmetatable({
    _provider = opts.provider,
    _player = opts.player,
    _cry = opts.cry,
    _mapMusic = opts.mapMusic,
    _currentMusic = nil,
    _currentEffect = nil,
    _effectPlayers = {},
    _fanfare = nil,
    _musicFade = nil,
    _cryActive = false,
  }, GameSound)
end

-- Resolves a sequence reference and starts it on the engine player,
-- returning the resolved sequence for the caller's bookkeeping.
---@param idOrSymbol integer|string
---@return table
function GameSound:_startSequence(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  local bank = self._provider:bank(sequence.bankId)
  self._player:play(sequence, bank)
  return sequence
end

-- Stops the player the current BGM runs on; no-op while no BGM reference
-- is held.
function GameSound:_stopBgmPlayer()
  if self._currentMusic == nil then
    return
  end
  local bgm = self._provider:sequence(self._currentMusic)
  self._player:stopPlayer(bgm.player.id)
end

-- `play` is the effect (SE) path: the sequence runs on its own player id,
-- so a later effect on the same player replaces the earlier one (the
-- engine's same-player replacement) while the player stays busy -- exactly
-- what an HGSS WaitSE observes through the player-state query.
---@param idOrSymbol integer|string
function GameSound:play(idOrSymbol)
  local sequence = self:_startSequence(idOrSymbol)
  self._currentEffect = sequence.id
  self._effectPlayers[sequence.player.id] = true
end

-- Stops the player the sequence plays on, leaving every other player (in
-- particular the BGM player) untouched.
---@param idOrSymbol integer|string
function GameSound:stop(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  self._player:stopPlayer(sequence.player.id)
end

-- True while the sequence's player has a running sequence. An unresolvable
-- reference surfaces the provider's unknown-sequence failure: a poll never
-- answers nil.
---@param idOrSymbol integer|string
---@return boolean
function GameSound:isEffectPlaying(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  return self._player:isPlayerPlaying(sequence.player.id)
end

-- The most recent effect started on any player (the infer-the-current-
-- effect path for an operand-less WaitSE), or nil before any effect.
---@return integer?
function GameSound:currentEffect()
  return self._currentEffect
end

---@param idOrSymbol integer|string
function GameSound:playMusic(idOrSymbol)
  self._currentMusic = self:_startSequence(idOrSymbol).id
end

-- Stops the current BGM and drops the reference; the StopBGM operand is an
-- erasure both at lowering and here (the service takes no arguments).
function GameSound:stopMusic()
  self:_stopBgmPlayer()
  self._currentMusic = nil
end

-- The resolved id of the current BGM reference, or nil while silent. The
-- reference survives a fade-out to 0 so a later fade-in can restore it.
---@return integer?
function GameSound:currentMusic()
  return self._currentMusic
end

-- The fanfare machine: pause the BGM player (the reference is kept for the
-- resume), play the fanfare through its own player, then hold the post-play
-- wait on field ticks before resuming the paused BGM.
---@param idOrSymbol integer|string
function GameSound:playFanfare(idOrSymbol)
  self:_stopBgmPlayer()
  local sequence = self:_startSequence(idOrSymbol)
  self._fanfare = { playerId = sequence.player.id, ticks = FANFARE_POST_WAIT_TICKS }
end

---@return boolean
function GameSound:isFanfarePlaying()
  return self._fanfare ~= nil
end

-- The cry boundary. Without an injected cry subsystem a reachable cry is
-- an attributed failure (the cry data path is its own workstream); with
-- one, the subsystem owns playback and the facade tracks activity for the
-- wait and stability predicates.
---@param species integer
---@param form integer
function GameSound:playCry(species, form)
  if self._cry == nil then
    Errors.raise(FieldErrors.AUDIO_CRY_UNAVAILABLE, "no cry subsystem is available", {
      species = species,
      form = form,
    })
  end
  self._cry:play(species, form)
  self._cryActive = true
end

---@return boolean
function GameSound:isCryFinished()
  if not self._cryActive then
    return true
  end
  if self._cry:isFinished() then
    self._cryActive = false
    return true
  end
  return false
end

-- Starts a fade-out in the command's own tick. A fade while one is already
-- active is skipped (the HGSS fade timer is nonzero); with no current BGM
-- the fade never starts and the script wait completes immediately. The
-- timer advances on field fixed ticks; the fade is frozen while a fanfare
-- is active.
---@param spec { target: integer, durationTicks: integer }
function GameSound:fadeMusicOut(spec)
  if self._musicFade ~= nil or self._currentMusic == nil then
    return
  end
  assert(spec.target ~= nil and spec.durationTicks, "fade-out spec requires a target and a duration")
  self._musicFade = { target = spec.target, ticks = spec.durationTicks }
end

-- Restores the current-music reference (restarting it, per the HGSS
-- fade-in path which starts the BGM at volume zero) and runs the same
-- fixed-tick timer.
---@param spec { durationTicks: integer }
function GameSound:fadeMusicIn(spec)
  if self._musicFade ~= nil or self._currentMusic == nil then
    return
  end
  assert(spec.durationTicks, "fade-in spec requires a duration")
  self:playMusic(self._currentMusic)
  self._musicFade = { ticks = spec.durationTicks }
end

---@return boolean
function GameSound:isMusicFadeActive()
  return self._musicFade ~= nil
end

-- Plays the map-header music reference from the injected field-policy
-- resolver. A nil resolver result means the map has no music: the current
-- BGM stops. Without a resolver the reset is an attributed failure rather
-- than a guess.
function GameSound:resetMusic()
  if self._mapMusic == nil then
    Errors.raise(FieldErrors.AUDIO_MAP_MUSIC_UNAVAILABLE, "no map-music resolver is available", {})
  end
  local reference = self._mapMusic()
  if reference == nil then
    self:stopMusic()
    return
  end
  self:playMusic(reference)
end

-- The temporary-music path belongs to the field scene-music state flow
-- (a later deliverable); until then a reachable call is an attributed
-- failure, never a no-op.
---@param idOrSymbol integer|string
function GameSound:temporaryMusic(idOrSymbol)
  Errors.raise(FieldErrors.AUDIO_TEMPORARY_MUSIC_UNSUPPORTED, "temporary music is not supported yet", {
    reference = idOrSymbol,
  })
end

-- Advances the game-semantic audio state once per field fixed tick: the
-- fanfare post-play wait (and the resume it ends with) and the music fade
-- timer, which is frozen while a fanfare is active.
function GameSound:updateFixed()
  if self._fanfare ~= nil and not self._player:isPlayerPlaying(self._fanfare.playerId) then
    self._fanfare.ticks = self._fanfare.ticks - 1
    if self._fanfare.ticks <= 0 then
      self:_completeFanfare()
    end
  end
  if self._musicFade ~= nil and self._fanfare == nil then
    self._musicFade.ticks = self._musicFade.ticks - 1
    if self._musicFade.ticks <= 0 then
      self:_completeMusicFade()
    end
  end
end

-- False while any script-observable transient is active (music fade,
-- fanfare, cry, a playable effect) so the field save boundary can refuse
-- capture; ordinary continuous map BGM is stable.
---@return boolean
function GameSound:isSaveStable()
  if self._musicFade ~= nil or self._fanfare ~= nil or self._cryActive then
    return false
  end
  for playerId in pairs(self._effectPlayers) do
    if self._player:isPlayerPlaying(playerId) then
      return false
    end
  end
  return true
end

-- Renders stereo PCM through the underlying engine player (the LÖVE sink
-- consumes this on the audio output clock, separate from the field tick).
---@param frames integer
---@return integer[]
function GameSound:render(frames)
  return self._player:render(frames)
end

-- Releases the fanfare player and replays the BGM reference paused at
-- playFanfare (playback position preservation is not a V1 requirement,
-- same stance as save resume).
function GameSound:_completeFanfare()
  local playerId = self._fanfare.playerId
  self._fanfare = nil
  self._player:stopPlayer(playerId)
  if self._currentMusic ~= nil then
    self:playMusic(self._currentMusic)
  end
end

-- Ends the active fade: a fade-out to target 0 stops the BGM player while
-- the current-music reference survives for a later fade-in; other targets
-- leave the BGM running.
function GameSound:_completeMusicFade()
  local fade = self._musicFade
  self._musicFade = nil
  if fade.target == 0 then
    self:_stopBgmPlayer()
  end
end

return GameSound
