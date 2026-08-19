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
-- wait the still-current BGM's timeline resumes, and a BGM replaced or
-- stopped during the fanfare is never resumed), fixed-tick fades (the
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
--
-- Fader ownership: each NNS player carries exactly one applied fader record
-- (level + at most one ramp) in this module. Script music fades, generic
-- sequence-volume moves, and fade-stop operations all create/replace that
-- same ramp, so no second authority can write the player. SequencePlayer
-- owns the instance fader used for voice updates; this module is the only
-- semantic ramp generator in the field-audio stack.

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.engine.src.audio.AudioErrors")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")

---@class GameSound
---@field private _provider AudioAssetProvider
---@field private _player SequencePlayer
---@field private _cry table?
---@field private _mapMusic fun(): integer|string|nil?
---@field private _currentMusic integer?
---@field private _fanfare table?
---@field private _faders table<integer, GameSoundPlayerFader>
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
---@field updateSoundFrame fun(self: GameSound)
---@field moveSequenceVolume fun(self: GameSound, idOrSymbol: integer|string, target: integer, durationFrames: integer)
---@field stopSequenceWithFade fun(self: GameSound, idOrSymbol: integer|string, durationFrames: integer)

-- One applied fader timeline per NNS player. `level` is the level this
-- module last asked SequencePlayer to apply (always 0..127 after the apply
-- boundary normalizes the source full-restore spelling 128). `ramp` is nil
-- or the one active ramp owning the player; `kind` tags a script music fade
-- ("music") so the BGM facade can answer its source fade polls without a
-- second level accumulator.
---@class GameSoundPlayerFader
---@field level integer
---@field ramp GameSoundFaderRamp?

-- A single ramp owning one player's fader for `durationFrames` 60 Hz sound
-- frames. `start` is the applied level at creation; `target` is the source
-- volume-domain goal (may be the full-restore spelling 128); the applied
-- level interpolates with the source cDiv formula and is normalized to
-- 0..127 only when it reaches SequencePlayer:setFader.
---@class GameSoundFaderRamp
---@field start integer
---@field target integer
---@field durationFrames integer
---@field elapsedFrames integer
---@field kind "music"|"generic"
---@field stopWhenDone boolean

local GameSound = {}
GameSound.__index = GameSound

-- The post-fanfare wait interval in sound frames at 60 Hz: HGSS PlayFanfare
-- sets a u16 timer to 0x0F and the fanfare stays "playing" until it counts
-- down after the fanfare player stops. At 60 Hz, 15 frames = 250 ms.
local FANFARE_POST_WAIT_FRAMES = 15

-- The strict player fader domain (SequencePlayer:setFader asserts 0..127)
-- and the source full-restore spelling accepted only at the GameSound
-- boundary (HGSS GF_SndHandleMoveVolume(0, 128, 15) on soundplate exit).
local PLAYER_FADER_FULL = 127
local SOURCE_FULL_RESTORE = 128
-- The fixed NNS player domain (SequencePlayer's PLAYER_COUNT): fader ramps
-- iterate ascending over these ids, never in Lua table order.
local NNS_PLAYER_COUNT = 16

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
    _fanfare = nil,
    _faders = {},
    _cryActive = false,
  }, GameSound)
end

-- Resolves a sequence reference and starts it on the engine player,
-- returning the resolved sequence for the caller's bookkeeping.
-- Starting/replacing a sequence is a synchronization boundary: SequencePlayer
-- creates a fresh instance at the full fader level 127, so this module's
-- record for that player is reset to full and idle immediately -- stale
-- ramp/level bookkeeping from a replaced sequence must never survive.
---@param idOrSymbol integer|string
---@return table
function GameSound:_startSequence(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  local bank = self._provider:bank(sequence.bankId)
  self._player:play(sequence, bank)
  self:_resetPlayerFader(sequence.player.id)
  return sequence
end

-- The fader record for `playerId`, created at the known actual full level
-- 127 when the player has no record yet. A player that never started a
-- sequence in this module is still created at full because that is what a
-- fresh SequencePlayer instance starts at; the record is only ever written
-- after a real sequence start or a ramp application.
---@param playerId integer
---@return GameSoundPlayerFader
function GameSound:_faderFor(playerId)
  local fader = self._faders[playerId]
  if fader == nil then
    fader = { level = PLAYER_FADER_FULL, ramp = nil }
    self._faders[playerId] = fader
  end
  return fader
end

-- Synchronizes the player's fader record to the state SequencePlayer actually
-- holds after creating a fresh instance: full level and no active ramp.
---@param playerId integer
function GameSound:_resetPlayerFader(playerId)
  self._faders[playerId] = { level = PLAYER_FADER_FULL, ramp = nil }
end

-- Applies a volume-domain level to the player through the strict
-- SequencePlayer:setFader contract, normalizing the source full-restore
-- spelling 128 to the player full level 127 exactly at this boundary.
-- Returns the level actually applied, so the module's record always matches
-- what SequencePlayer holds.
---@param playerId integer
---@param level integer
---@return integer
function GameSound:_applyFader(playerId, level)
  if level > PLAYER_FADER_FULL then
    level = PLAYER_FADER_FULL
  end
  self._player:setFader(playerId, level)
  return level
end

-- Creates (or replaces) the player's single ramp. The ramp interpolates from
-- the current applied level -- never from a stale original-ramp start -- and
-- carries the source target: a full-restore spelling 128 ramps toward 128
-- and is normalized to 127 only when the interpolated level is applied, so
-- the exact final-frame value matches the source move. The start level is
-- pushed to the player immediately, matching the HGSS command's first volume
-- move happening in its start tick rather than on the first fixed tick.
-- `kind` tags script music fades for the BGM facade polls; `stopWhenDone`
-- makes the final applied frame stop the player.
---@param playerId integer
---@param target integer
---@param durationFrames integer
---@param kind "music"|"generic"
---@param stopWhenDone boolean
function GameSound:_replaceFaderRamp(playerId, target, durationFrames, kind, stopWhenDone)
  local fader = self:_faderFor(playerId)
  self:_applyFader(playerId, fader.level)
  fader.ramp = {
    start = fader.level,
    target = target,
    durationFrames = durationFrames,
    elapsedFrames = 0,
    kind = kind,
    stopWhenDone = stopWhenDone,
  }
end

-- Stops the player the current BGM runs on; no-op while no BGM reference
-- is held. Stopping a player drops its stale fader bookkeeping so a future
-- sequence on that player cannot inherit a record that no longer matches a
-- SequencePlayer instance.
function GameSound:_stopBgmPlayer()
  if self._currentMusic == nil then
    return
  end
  local bgm = self._provider:sequence(self._currentMusic)
  self._player:stopPlayer(bgm.player.id)
  self:_resetPlayerFader(bgm.player.id)
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
-- particular the BGM player) untouched. Stopping drops the player's fader
-- record so stale ramp state cannot outlive the instance it described.
---@param idOrSymbol integer|string
function GameSound:stop(idOrSymbol)
  local sequence = self._provider:sequence(idOrSymbol)
  self._player:stopPlayer(sequence.player.id)
  self:_resetPlayerFader(sequence.player.id)
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
  self:_stopBgmPlayer()
  self._currentMusic = self:_startSequence(idOrSymbol).id
end

-- Stops the current BGM, drops the reference, and cancels its fade (a
-- music fade belongs to the BGM it fades; the StopBGM operand is an
-- erasure both at lowering and here -- the service takes no arguments).
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
  self._fanfare = { playerId = sequence.player.id, frames = FANFARE_POST_WAIT_FRAMES }
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
-- script operand is a target LEVEL, 0..127). A fade while the current music
-- still owns an active script-music fade is skipped -- the HGSS fade timer
-- is nonzero, so the volume move is ignored -- and with no current BGM the
-- fade never starts and the script wait completes immediately. The ramp is
-- the player's single unified ramp, tagged as a music fade.
---@param spec { target: integer, durationTicks: integer }
function GameSound:fadeMusicOut(spec)
  if self._currentMusic == nil then
    return
  end
  local bgm = self._provider:sequence(self._currentMusic)
  local playerId = bgm.player.id
  local fader = self:_faderFor(playerId)
  if fader.ramp ~= nil and fader.ramp.kind == "music" then
    return
  end
  assert(spec.target ~= nil and spec.durationTicks, "fade-out spec requires a target and a duration")
  assert(spec.target >= 0 and spec.target <= 127, "fade-out target must be a level in 0..127")
  assert(spec.durationTicks > 0 and spec.durationTicks % 1 == 0, "fade-out duration must be a positive tick count")
  self:_replaceFaderRamp(playerId, spec.target, spec.durationTicks, "music", false)
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
  local bgm = self._provider:sequence(self._currentMusic)
  local playerId = bgm.player.id
  local fader = self:_faderFor(playerId)
  -- The fade-in snap: the unified level becomes 0 immediately and the player
  -- hears it before the ramp starts (the HGSS zero-length move). The ramp
  -- creation pushes the snapped 0 as its start level.
  fader.level = 0
  fader.ramp = nil
  self:_replaceFaderRamp(playerId, PLAYER_FADER_FULL, spec.durationTicks, "music", false)
end

---@return boolean
function GameSound:isMusicFadeActive()
  if self._currentMusic == nil then
    return false
  end
  local bgm = self._provider:sequence(self._currentMusic)
  local fader = self._faders[bgm.player.id]
  return fader ~= nil and fader.ramp ~= nil and fader.ramp.kind == "music"
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
-- the special scripted-music player) and becomes the current BGM identity
-- for the purposes of stop/fade/query operations, but does NOT update the
-- base field-music reference (that remains separate for soundplate bank
-- selection and future resetMusic).
---@param idOrSymbol integer|string
function GameSound:temporaryMusic(idOrSymbol)
  local sequence = self:_startSequence(idOrSymbol)
  self._currentMusic = sequence.id
end

-- Advances the game-semantic audio state once per 60 Hz sound frame: the
-- fanfare post-play wait (and the resume it ends with) first, then the
-- per-player fader ramps. The fanfare runs before the ramps so the
-- fanfare-completion frame decides whether a script music fade stays frozen:
-- while a fanfare is active the HGSS DoSoundUpdateFrame trace only
-- decrements the fade timer when no fanfare is playing, so the music fade
-- ramp is skipped while generic ramps keep advancing (only the script music
-- fade carries the freeze). Called by FieldRuntime at 60 Hz frequency.
function GameSound:updateSoundFrame()
  if self._fanfare ~= nil and not self._player:isPlayerPlaying(self._fanfare.playerId) then
    self._fanfare.frames = self._fanfare.frames - 1
    if self._fanfare.frames <= 0 then
      self:_completeFanfare()
    end
  end
  self:_advanceFaderRamps()
end

-- Advances each player's single ramp once per sound frame. Iteration is in
-- ascending player-id order (never pairs()) so simultaneous ramp
-- completions/stops are deterministic. Each active ramp applies exactly one
-- interpolated level per frame; a ramp completes -- and, when requested,
-- stops the player -- only after its final frame has applied the target
-- level. The script music fade freeze is the fanfare's: while a fanfare is
-- active, ramps tagged as music fades do not advance.
function GameSound:_advanceFaderRamps()
  for playerId = 0, NNS_PLAYER_COUNT - 1 do
    local fader = self._faders[playerId]
    if fader ~= nil and fader.ramp ~= nil then
      local ramp = fader.ramp
      if not (self._fanfare ~= nil and ramp.kind == "music") then
        ramp.elapsedFrames = ramp.elapsedFrames + 1
        local level = ramp.start
          + NnsSoundMath.cDiv(ramp.elapsedFrames * (ramp.target - ramp.start), ramp.durationFrames)
        -- Store the level actually applied (a full-restore interpolation may
        -- compute 128 on its final frame; the record keeps the normalized 127
        -- so it always equals what SequencePlayer holds).
        fader.level = self:_applyFader(playerId, level)
        if ramp.elapsedFrames >= ramp.durationFrames then
          fader.ramp = nil
          if ramp.stopWhenDone then
            self._player:stopPlayer(playerId)
            self:_resetPlayerFader(playerId)
          end
        end
      end
    end
  end
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

-- Moves a sequence's player fader to the target level over the duration in
-- 60 Hz sound frames using frame-exact linear interpolation. The target is
-- an integer in the source volume domain 0..128: the HGSS full-restore
-- spelling 128 is accepted (and normalized to player level 127 at the apply
-- boundary) while any other out-of-domain value is a programming-contract
-- violation. Starting a new ramp replaces any active ramp on the same
-- player from the current applied level, and replaces a script music fade
-- ramp -- which also ends that fade's timer because no active script fade
-- remains to poll.
---@param idOrSymbol integer|string
---@param target integer
---@param durationFrames integer
function GameSound:moveSequenceVolume(idOrSymbol, target, durationFrames)
  assert(target >= 0 and target <= SOURCE_FULL_RESTORE, "volume target must be an integer in 0..128")
  assert(durationFrames > 0 and durationFrames % 1 == 0, "fader ramp duration must be a positive integer")

  local sequence = self._provider:sequence(idOrSymbol)
  self:_replaceFaderRamp(sequence.player.id, target, durationFrames, "generic", false)
end

-- Stops a sequence's player after fading to silence over the duration in
-- 60 Hz sound frames. The player stops only after the final ramp frame has
-- applied level 0. Used by soundplate environmental audio to fade out
-- before stopping.
---@param idOrSymbol integer|string
---@param durationFrames integer
function GameSound:stopSequenceWithFade(idOrSymbol, durationFrames)
  assert(durationFrames > 0 and durationFrames % 1 == 0, "fade-stop duration must be a positive integer")

  local sequence = self._provider:sequence(idOrSymbol)
  self:_replaceFaderRamp(sequence.player.id, 0, durationFrames, "generic", true)
end

-- Starts `sequenceRef` with an explicit donor bank `bankRef` whose id may
-- differ from the sequence's declared bankId. This is the sole
-- bank-mismatch exception for environmental donor-bank soundplates. The
-- fader bookkeeping is reset exactly like any fresh sequence start.
---@param sequenceRef integer|string
---@param bankRef integer|string
function GameSound:playWithBankOverride(sequenceRef, bankRef)
  local sequence = self._provider:sequence(sequenceRef)
  local bank = self._provider:bank(bankRef)
  self._player:playWithBankOverride(sequence, bank)
  self:_resetPlayerFader(sequence.player.id)
end

return GameSound
