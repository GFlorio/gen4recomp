-- GameSound: the semantic audio facade field scripts receive as their
-- `audio` service. It wraps the real engine audio (AudioAssetProvider +
-- SequencePlayer + VoiceMixer) and owns the script-observable semantics:
-- BGM (play/stop/replace/current; a music fade belongs to the current BGM,
-- so stopping or replacing the BGM cancels its fade), effects (play/stop;
-- waits follow the HGSS IsSEPlaying model -- resolve the sequence's player
-- and test that player's playback state, never an individual host-source
-- token), the fanfare state machine (the HGSS PlayFanfare path PAUSES the
-- BGM player: the sequence timeline freezes and the paused player's
-- channels are released with the forced release override -- no channel or
-- sample state is preserved; after the fanfare and its 15-tick post-play
-- wait, which advances on field fixed ticks and is the u16 0x0F the HGSS
-- path sets, the still-current BGM's timeline resumes, and a BGM replaced
-- or stopped during the fanfare is never resumed), fixed-tick fades (the
-- HGSS GF_SndStartFadeOutBGM/FadeInBGM model: the fade state carries
-- starting level/target/total duration/elapsed, the level ramps linearly
-- per tick into a dB-domain attenuation the player pushes to the mixer's
-- per-voice fader, a fade-out while one is active is skipped while a
-- fade-in restarts from silence, a fade never stops the BGM player, and
-- the fade timer is frozen while a fanfare is active per the HGSS
-- DoSoundUpdateFrame trace), and the cry boundary (a reachable cry without
-- a cry subsystem is an attributed failure; the cry data path is a
-- separate subsystem the production composition supplies). All polls
-- return booleans, never nil. The only injectable boundaries are the cry
-- subsystem and the map-music resolver (the field-music policy owner);
-- everything else runs the real engine audio. PCM rendering is the output
-- sink's business: GameSound never renders.

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.engine.src.audio.AudioErrors")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")

---@class GameSound
---@field private _provider AudioAssetProvider
---@field private _player SequencePlayer
---@field private _cry table?
---@field private _mapMusic fun(): integer|string|nil?
---@field private _currentMusic integer?
---@field private _musicLevel integer
---@field private _fanfare table?
---@field private _musicFade table?
---@field private _cryActive boolean
---@field new fun(opts: { provider: AudioAssetProvider, player: SequencePlayer, cry: table?, mapMusic: fun(): integer|string|nil? }): GameSound
---@field play fun(self: GameSound, idOrSymbol: integer|string)
---@field stop fun(self: GameSound, idOrSymbol: integer|string)
---@field isEffectPlaying fun(self: GameSound, idOrSymbol: integer|string): boolean
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
    _musicLevel = 127,
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
  self:_startSequence(idOrSymbol)
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

-- Starts `idOrSymbol` as the current BGM. The retail BGM role spans two
-- player slots (the fixed field-music slot and the special scripted-music
-- slot), so a replacement may land on a different player than its
-- predecessor: the previous BGM's player is explicitly stopped first, so
-- two field BGMs are never active while `_currentMusic` points at one.
-- Replacing the BGM also cancels any fade the previous BGM owned (a music
-- fade belongs to the BGM it fades, never to a later replacement).
---@param idOrSymbol integer|string
function GameSound:playMusic(idOrSymbol)
  self._musicFade = nil
  self:_stopBgmPlayer()
  self._currentMusic = self:_startSequence(idOrSymbol).id
  self._musicLevel = 127
end

-- Stops the current BGM, drops the reference, and cancels its fade (a
-- music fade belongs to the BGM it fades; the StopBGM operand is an
-- erasure both at lowering and here -- the service takes no arguments).
function GameSound:stopMusic()
  self:_stopBgmPlayer()
  self._currentMusic = nil
  self._musicFade = nil
end

-- The resolved id of the current BGM reference, or nil while silent. The
-- reference survives a fade-out to 0 so a later fade-in can restore it.
---@return integer?
function GameSound:currentMusic()
  return self._currentMusic
end

-- The fanfare machine, per the HGSS PlayFanfare path: the BGM player is
-- PAUSED -- its timeline freezes and the pause releases the player's
-- channels with the forced release override, so no channel or sample state
-- survives the pause -- and the fanfare plays through its own player, then
-- the post-play wait is held on field ticks before the pause lifts. Only
-- the still-current BGM is resumed at completion; a BGM replaced or
-- stopped during the fanfare is gone for good (playMusic/stopMusic already
-- stopped its player). Without a current BGM the pause is a no-op.
---@param idOrSymbol integer|string
function GameSound:playFanfare(idOrSymbol)
  if self._currentMusic ~= nil then
    local bgm = self._provider:sequence(self._currentMusic)
    self._player:pausePlayer(bgm.player.id)
  end
  local sequence = self:_startSequence(idOrSymbol)
  self._fanfare = { playerId = sequence.player.id, ticks = FANFARE_POST_WAIT_TICKS }
end

---@return boolean
function GameSound:isFanfarePlaying()
  return self._fanfare ~= nil
end

-- The cry boundary. Without an injected cry subsystem a reachable cry is
-- an attributed failure; the cry data path is a separate subsystem and
-- plays through it when injected, with the facade tracking activity for
-- the wait and stability predicates.
---@param species integer
---@param form integer
function GameSound:playCry(species, form)
  if self._cry == nil then
    Errors.raise(AudioErrors.AUDIO_CRY_UNAVAILABLE, "no cry subsystem is available", {
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

-- Starts a fade-out from the current music level to the target level over
-- the requested ticks (the HGSS GF_SndStartFadeOutBGM model: the first
-- script operand is a target LEVEL, 0..127). A fade while one is already
-- active is skipped -- the HGSS fade timer is nonzero, so the volume move
-- is ignored -- and with no current BGM the fade never starts and the
-- script wait completes immediately.
---@param spec { target: integer, durationTicks: integer }
function GameSound:fadeMusicOut(spec)
  if self._musicFade ~= nil or self._currentMusic == nil then
    return
  end
  assert(spec.target ~= nil and spec.durationTicks, "fade-out spec requires a target and a duration")
  assert(spec.target >= 0 and spec.target <= 127, "fade-out target must be a level in 0..127")
  assert(spec.durationTicks > 0 and spec.durationTicks % 1 == 0, "fade-out duration must be a positive tick count")
  self._musicFade = {
    startingLevel = self._musicLevel,
    target = spec.target,
    totalDuration = spec.durationTicks,
    elapsed = 0,
  }
  -- The fade starts from the current level in its start tick (the HGSS
  -- command's first volume move happens immediately, not on the first
  -- fixed tick): push the starting level so the player's fader matches.
  self:_pushMusicLevel(self._musicLevel)
end

-- Starts a fade-in: the BGM first snaps to silence, then ramps to full
-- over the requested ticks (the HGSS GF_SndStartFadeInBGM path, which
-- moves the volume to 0 with a zero-length ramp before the real one).
-- Unlike a fade-out there is no active-fade guard: a fade-in issued while
-- a fade is active replaces it (snap + new duration). The BGM player is
-- never replayed -- the fade only moves the level of the still-playing
-- player.
---@param spec { durationTicks: integer }
function GameSound:fadeMusicIn(spec)
  if self._currentMusic == nil then
    return
  end
  assert(spec.durationTicks, "fade-in spec requires a duration")
  assert(spec.durationTicks > 0 and spec.durationTicks % 1 == 0, "fade-in duration must be a positive tick count")
  self._musicFade = {
    startingLevel = 0,
    target = 127,
    totalDuration = spec.durationTicks,
    elapsed = 0,
  }
  self._musicLevel = 0
  self:_pushMusicLevel(0)
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
    Errors.raise(AudioErrors.AUDIO_MAP_MUSIC_UNAVAILABLE, "no map-music resolver is available", {})
  end
  local reference = self._mapMusic()
  if reference == nil then
    self:stopMusic()
    return
  end
  self:playMusic(reference)
end

-- The temporary-music path (ScrCmd_TempBGM): the referenced special-music
-- sequence starts on its own player slot (the retail corpus always targets
-- the special scripted-music player) and plays over the current field BGM
-- without replacing the BGM reference.
---@param idOrSymbol integer|string
function GameSound:temporaryMusic(idOrSymbol)
  self:_startSequence(idOrSymbol)
end

-- Advances the game-semantic audio state once per field fixed tick: the
-- fanfare post-play wait (and the resume it ends with) and the music fade
-- timer, which is frozen while a fanfare is active (the HGSS
-- DoSoundUpdateFrame trace only decrements the fade timer while no fanfare
-- is playing).
function GameSound:updateFixed()
  if self._fanfare ~= nil and not self._player:isPlayerPlaying(self._fanfare.playerId) then
    self._fanfare.ticks = self._fanfare.ticks - 1
    if self._fanfare.ticks <= 0 then
      self:_completeFanfare()
    end
  end
  if self._musicFade ~= nil and self._fanfare == nil then
    self:_advanceMusicFade()
  end
end

-- One field tick of the active fade: the level ramps linearly from the
-- starting level toward the target in the volume domain (the NNS fader's
-- s32 interpolation), the player's fader follows, and the fade completes --
-- and the script wait unblocks -- exactly when the elapsed reaches the
-- total duration. A fade never stops the BGM player: it keeps playing at
-- the faded level.
function GameSound:_advanceMusicFade()
  local fade = self._musicFade
  fade.elapsed = fade.elapsed + 1
  local level = fade.startingLevel
    + NnsSoundMath.cDiv(fade.elapsed * (fade.target - fade.startingLevel), fade.totalDuration)
  self:_pushMusicLevel(level)
  if fade.elapsed >= fade.totalDuration then
    self._musicFade = nil
    self._musicLevel = fade.target
  end
end

-- Moves the current BGM player's fader to the volume-domain level; the
-- player converts it to the dB-domain attenuation at its next control-step
-- push.
---@param level integer
function GameSound:_pushMusicLevel(level)
  local bgm = self._provider:sequence(self._currentMusic)
  self._player:setFader(bgm.player.id, level)
end

-- Releases the fanfare player and lifts the current BGM's transport pause:
-- only a still-current BGM is resumed -- a BGM replaced or stopped during
-- the fanfare is gone for good, because playMusic/stopMusic already
-- stopped its player. Resume never resurrects the paused player's old
-- channels: the pause released them.
function GameSound:_completeFanfare()
  local playerId = self._fanfare.playerId
  self._fanfare = nil
  self._player:stopPlayer(playerId)
  if self._currentMusic ~= nil then
    local bgm = self._provider:sequence(self._currentMusic)
    self._player:resumePlayer(bgm.player.id)
  end
end

return GameSound
