-- GameSound contract: the semantic audio facade field scripts receive as
-- their `audio` service. It wraps the real engine audio (AudioAssetProvider
-- + SequencePlayer + VoiceMixer) and owns the script-observable semantics:
-- BGM (play/stop/replace/current; a music fade belongs to the current BGM,
-- so stopping or replacing the BGM cancels its fade), effects (play/stop;
-- waits follow the HGSS IsSEPlaying model -- the wait sequence is always
-- resolved from the script operand, never from a "current effect"
-- inference), the fanfare state machine (HGSS PlayFanfare PAUSES the BGM
-- player -- the timeline freezes and the paused player's channels are
-- released with the forced release override; after the fanfare and its
-- 15-tick post-wait the still-current BGM's timeline resumes, and a BGM
-- replaced or stopped during the fanfare is never resumed), fixed-tick
-- fades (the HGSS GF_SndStartFadeOutBGM/FadeInBGM model: the fade state
-- carries starting level/target/total/elapsed, the level ramps linearly per
-- tick into a dB-domain attenuation the mixer applies through its per-voice
-- fader hook, a fade-out while one is active is skipped while a fade-in
-- restarts from silence, a fade never stops the BGM player, and the fade
-- timer is frozen while a fanfare is active per DoSoundUpdateFrame), and
-- the cry boundary (a reachable cry without a cry subsystem is an
-- attributed failure; production composition supplies the subsystem). PCM
-- rendering is the output sink's business: GameSound never renders. All
-- polls return booleans, never nil. The only injectable boundaries are the
-- cry subsystem and the map-music resolver; everything else runs the real
-- engine audio.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local GameSound = require("libs.engine.src.audio.GameSound")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")

local T = {}

local SAMPLE_RATE = 48000
-- Three distinct content-addressed waves: BGM, effect, fanfare.
local WAVE_A = { 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000 }
local WAVE_B = { 10000, 9000, 8000, 7000 }
local WAVE_C = { 500, 1000, 1500, 2000, 2500, 3000 }

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

local function voice(key)
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = 0,
  }
end

local function bank()
  return AudioFixture.bank(12, "BANK_TEST", { AudioFixture.key(1), AudioFixture.key(2), AudioFixture.key(3) }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
    [2] = { kind = "direct", voice = voice(AudioFixture.key(3)) },
  })
end

local function seq(id, symbol, playerId, instructions)
  return AudioFixture.sequence(id, symbol, 12, playerId, { entry = 1, instructions = instructions }, {
    id = playerId,
    initialVolume = 127,
    playerPriority = 64,
    channelPriority = 64,
  })
end

-- The synthetic archive the facade plays: a looping BGM on player 1, a
-- finite effect and a second finite effect (longer, same player) on player
-- 2, the fanfare on player 3, a second looping BGM on player 1, and a
-- long-gated BGM on player 1 whose note never expires inside the fade tests
-- (so the fade windows are single-voice with no retrigger).
local function defaultSequences()
  return {
    [0] = seq(0, "SEQ_TEST_BGM", 1, {
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "jump", target = 2 },
    }),
    [1] = seq(1, "SEQ_TEST_EFFECT", 2, {
      { op = "program", program = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
    [2] = seq(2, "SEQ_TEST_FANFARE", 3, {
      { op = "program", program = 2 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
    [3] = seq(3, "SEQ_TEST_EFFECT_B", 2, {
      { op = "program", program = 1 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "end" },
    }),
    [4] = seq(4, "SEQ_TEST_BGM_B", 1, {
      { op = "program", program = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "jump", target = 2 },
    }),
    [5] = seq(5, "SEQ_TEST_BGM_LONG", 1, {
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }
end

local function engineBundle(sequences)
  local keyA, keyB, keyC = AudioFixture.key(1), AudioFixture.key(2), AudioFixture.key(3)
  local bundle = AudioFixture.bundle()
  local indexSequences, indexPlayers, indexBanks, sequenceBySymbol = {}, {}, {}, {}
  for id, sequence in pairs(sequences) do
    indexSequences[id] = {
      id = id,
      symbol = sequence.symbol,
      bankId = sequence.bankId,
      playerId = sequence.player.id,
    }
    sequenceBySymbol[sequence.symbol] = id
    if indexPlayers[sequence.player.id] == nil then
      indexPlayers[sequence.player.id] = {
        id = sequence.player.id,
        maxSequences = 16,
        channelMask = 0xFFFF,
      }
    end
  end
  indexBanks[12] = { id = 12, symbol = "BANK_TEST" }
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = indexBanks
  bundle.index.sequenceBySymbol = sequenceBySymbol
  bundle.index.bankBySymbol = { BANK_TEST = 12 }
  bundle.sequences = sequences
  bundle.banks = { [12] = bank() }
  bundle.samples = {
    [keyA] = AudioFixture.pcm16le(WAVE_A),
    [keyB] = AudioFixture.pcm16le(WAVE_B),
    [keyC] = AudioFixture.pcm16le(WAVE_C),
  }
  bundle.sampleMetadata = {
    [keyA] = AudioFixture.sampleMetadata(
      keyA,
      { frames = #WAVE_A, sampleRate = SAMPLE_RATE, loop = { startFrame = 0, endFrame = #WAVE_A } }
    ),
    [keyB] = AudioFixture.sampleMetadata(
      keyB,
      { frames = #WAVE_B, sampleRate = SAMPLE_RATE, loop = { startFrame = 0, endFrame = #WAVE_B } }
    ),
    [keyC] = AudioFixture.sampleMetadata(
      keyC,
      { frames = #WAVE_C, sampleRate = SAMPLE_RATE, loop = { startFrame = 0, endFrame = #WAVE_C } }
    ),
  }
  return bundle
end

-- A facade over the real engine audio; only the out-of-scope boundaries
-- (cry subsystem, map-music resolver) are injectable. The mixer's
-- updateVoice is wrapped to record the per-voice fader values the player
-- pushes at its control cadence: `readings` holds {channel, fader} pairs,
-- channel 4 being the first-allocated BGM voice in these fixtures (the NNS
-- sChannelAllocationOrder starts at 4) and the fanfare's voice landing on
-- channel 5.
-- Returns sound, player, spy.
local function newGameSound(sequences, opts)
  opts = opts or {}
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(engineBundle(sequences or defaultSequences())))
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local spy = { readings = {}, faderWrites = {} }
  local realUpdateVoice = mixer.updateVoice
  -- The fader spy overrides the typed mixer's method to observe the per-voice
  -- fader the player pushes at its control cadence.
  --[[@cast mixer any]]
  mixer.updateVoice = function(self, handle, partial)
    spy.readings[#spy.readings + 1] = { channel = handle.channel, fader = partial.fader }
    return realUpdateVoice(self, handle, partial)
  end
  local player = SequencePlayer.new({
    sampleRate = SAMPLE_RATE,
    mixer = mixer,
    provider = provider,
  })
  -- The player-fader spy records every level GameSound asks the engine player
  -- to apply, in application order, so the one-level-per-player contract is
  -- observable as exact level sequences without rendering.
  --[[@cast player any]]
  local realSetFader = player.setFader
  player.setFader = function(self, playerId, level)
    spy.faderWrites[#spy.faderWrites + 1] = { playerId = playerId, level = level }
    return realSetFader(self, playerId, level)
  end
  local sound = GameSound.new({
    provider = provider,
    player = player,
    cry = opts.cry,
    mapMusic = opts.mapMusic,
  })
  return sound, player, spy
end

local function left(pcm, frames)
  local out = {}
  for i = 1, frames do
    out[i] = pcm[i * 2 - 1]
  end
  return out
end

-- The post-fanfare wait interval in field ticks: HGSS PlayFanfare sets a
-- u16 timer to 0x0F and the fanfare stays "playing" until it counts down
-- after the fanfare player stops (sound.c DoSoundUpdateFrame /
-- GF_SndIsFanfarePlaying).
local FANFARE_POST_WAIT_TICKS = 15

-- The peak absolute left-channel sample of a rendered window (the window
-- helpers return mono left-channel data, so every entry is sampled).
local function maxAbs(pcm)
  local m = 0
  for i = 1, #pcm do
    local value = math.abs(pcm[i])
    if value > m then
      m = value
    end
  end
  return m
end

-- Applies `ticks` field ticks to the music fade and renders one control
-- period (250 frames at 48 kHz) so the boundary push reaches the mixer;
-- returns the fader value the BGM voice (channel 4, the first-allocated
-- channel of these fixtures) last carried, or nil when no fader was ever
-- pushed. A fade's fader is a dB-domain attenuation:
-- 0 is full volume and -0x8000 the fully attenuated clamp.
local function advanceFade(sound, player, spy, ticks)
  for _ = 1, ticks do
    sound:updateSoundFrame()
  end
  player:render(250)
  for i = #spy.readings, 1, -1 do
    local reading = spy.readings[i]
    if reading.channel == 4 then
      return reading.fader
    end
  end
  return nil
end

-- Renders one 250-frame window fully at the fade level applied by the last
-- advanceFade (the apply window's boundary frame carries the new level; the
-- following window hears it throughout).
local function measureFade(player)
  return left(player:render(250), 250)
end

-- True while `value` is a number strictly between the given bounds (the
-- fader is nil until a production path pushes it, which the fade contracts
-- must fail on cleanly).
local function strictlyBetween(value, low, high)
  return value ~= nil and value > low and value < high
end

function T.bgm_plays_tracks_current_music_and_stops()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  player:render(250)
  Assert.equal(sound:currentMusic(), 0, "currentMusic is the resolved sequence id")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the bgm player plays")
  Assert.isTrue(maxAbs(left(player:render(500), 500)) > 0, "the bgm plays")
  sound:stopMusic()
  Assert.isNil(sound:currentMusic())
  Assert.isFalse(sound:isEffectPlaying("SEQ_TEST_BGM"), "stopMusic stops the bgm player")
  -- The released voices ring out briefly, then the mix falls silent (the
  -- stopped player never retriggers its loop).
  player:render(600)
  Assert.equal(maxAbs(left(player:render(500), 500)), 0, "the stopped bgm falls silent")
end

function T.play_music_replaces_the_running_bgm_on_its_player()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  player:render(250)
  sound:playMusic("SEQ_TEST_BGM_B")
  player:render(250)
  Assert.equal(sound:currentMusic(), 4)
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM_B"), "the replacement plays")
  Assert.isTrue(maxAbs(left(player:render(500), 500)) > 0, "the replacement is audible")
end

function T.effects_overlap_bgm_and_report_player_completion()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:play(1)
  Assert.isTrue(sound:isEffectPlaying(1), "the effect is playing on its player")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the bgm plays under the effect")
  Assert.isTrue(maxAbs(left(player:render(600), 600)) > 0, "bgm and effect mix")
  -- The duration-1 effect ends at the second tempoCounter tick (frame 750
  -- at default tempo), so 1000 frames complete it.
  player:render(400)
  Assert.isFalse(sound:isEffectPlaying(1), "the effect completed; the bgm player is untouched")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the bgm outlives the effect")
end

-- The HGSS wait model (IsSEPlaying): resolve the sequence's player and test
-- that player's playback state, not an individual host-source token.
function T.effect_waits_follow_the_sequence_player_state()
  local sound, player = newGameSound()
  Assert.isFalse(sound:isEffectPlaying(1), "never-played effects report not playing")
  sound:play(1)
  sound:play(3)
  Assert.isTrue(sound:isEffectPlaying(1), "a later effect on the same player keeps the player busy")
  Assert.isTrue(sound:isEffectPlaying(3))
  player:render(500)
  Assert.isTrue(sound:isEffectPlaying(1), "the replacement effect keeps its player busy through its window")
  -- At default tempo 120 a player ticks every two sound intervals: the
  -- effect's duration-2 note gates for two ticks (ending at the third tick,
  -- frame 1250), so 1500 frames cover the full window.
  player:render(1000)
  Assert.isFalse(sound:isEffectPlaying(1), "the player's sequence ended")
  Assert.isFalse(sound:isEffectPlaying(3))
end

function T.stop_effect_stops_only_its_player()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:play(1)
  player:render(200)
  sound:stop(1)
  Assert.isFalse(sound:isEffectPlaying(1))
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the bgm survives the effect stop")
  Assert.isTrue(maxAbs(left(player:render(500), 500)) > 0, "the bgm keeps rendering")
end

-- The fanfare machine on the transport-pause model (the NNS
-- SND_PlayerPause the HGSS PlayFanfare path uses): the BGM player's
-- timeline is paused -- the sequence stays held and the player still
-- reports playing -- and its channels are released with the forced release
-- override; no sample or envelope state is preserved. After the fanfare
-- and its 15-tick post-wait the still-current BGM's timeline resumes from
-- its paused position; the fanfare never stops the BGM player and never
-- replays it from the start.
function T.fanfare_pauses_the_bgm_player_and_resumes_its_timeline()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  player:render(250)
  sound:playFanfare("SEQ_TEST_FANFARE")
  Assert.isTrue(sound:isFanfarePlaying())
  -- The BGM player is paused, not stopped: its sequence is still held.
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the bgm player is paused, not stopped, during the fanfare")
  -- The fanfare plays through the pause; its duration-1 note ends at the
  -- second tempoCounter tick (frame 750 at default tempo), so 1000 frames
  -- complete the sequence and start the post-wait.
  Assert.isTrue(maxAbs(left(player:render(1000), 1000)) > 0, "the fanfare plays while the bgm timeline is paused")
  Assert.isTrue(sound:isFanfarePlaying(), "the post-fanfare wait interval is still fanfare-playing")
  for _ = 1, FANFARE_POST_WAIT_TICKS - 1 do
    sound:updateSoundFrame()
  end
  Assert.isTrue(sound:isFanfarePlaying(), "the interval holds for its full length")
  sound:updateSoundFrame()
  Assert.isFalse(sound:isFanfarePlaying(), "the interval expired")
  -- The still-current bgm's timeline resumes from its paused position and
  -- its loop renders again; the released voice is never resurrected. The
  -- paused player re-notes on its second interval after resume (frame 500),
  -- so 750 frames carry the re-note's audible window.
  Assert.equal(sound:currentMusic(), 0, "the fanfare never stops the bgm reference")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the resumed bgm player still plays")
  Assert.isTrue(maxAbs(left(player:render(750), 750)) > 0, "the resumed bgm renders again")
end

-- Fades follow the HGSS GF_SndStartFadeOutBGM model (asm/unk_02005D10.s +
-- Diamond's unk_020051F4.c): the level ramps linearly from the starting
-- level to the target over the requested ticks, the attenuation reaches
-- the mixer as a dB-domain per-voice fader (clamped at -0x8000), the timer
-- and the perceptual volume advance together, and the fade-out to 0
-- reaches silence at exactly the target tick -- the BGM player is never
-- stopped by a fade (it keeps playing at the faded level).
function T.fade_out_ramps_the_volume_to_the_target_level_over_its_ticks()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  Assert.isTrue(sound:isMusicFadeActive())
  -- tick 0: the fade starts from the full level.
  Assert.equal(advanceFade(sound, player, spy, 0), 0, "tick 0 starts from the full level")
  Assert.equal(maxAbs(measureFade(player)), 8000, "the bgm is at full volume while the fade starts")
  -- tick N/2: a strictly intermediate attenuation; the perceptual volume
  -- follows the timer.
  local level15 = advanceFade(sound, player, spy, 15)
  Assert.isTrue(strictlyBetween(level15, -32768, 0), "tick N/2 carries a strictly intermediate attenuation")
  local amp15 = maxAbs(measureFade(player))
  Assert.isTrue(amp15 > 0 and amp15 < 8000, "the perceptual volume at tick N/2 is strictly between full and silence")
  -- tick N-1: still mid-fade, still quieter, still audible.
  local level29 = advanceFade(sound, player, spy, 14)
  Assert.isTrue(strictlyBetween(level29, -32768, level15), "the attenuation keeps progressing on the last active tick")
  Assert.isTrue(sound:isMusicFadeActive(), "the fade holds through durationTicks-1 updates")
  local amp29 = maxAbs(measureFade(player))
  Assert.isTrue(amp29 > 0 and amp29 < amp15, "the last active tick is audible but quieter")
  -- tick N: the target level exactly -- the fade reaches silence, it does
  -- not jump to stop early -- and the wait unblocks.
  Assert.equal(advanceFade(sound, player, spy, 1), -32768, "tick N reaches the -0x8000 target attenuation")
  Assert.isFalse(sound:isMusicFadeActive(), "the fade completes at exactly durationTicks updates")
  -- The BGM player was never stopped: the reference survives and the player
  -- still holds the sequence, silent at the target level (HGSS keeps the
  -- BGM player running after a fade-out to 0).
  Assert.equal(sound:currentMusic(), 5, "the current-music reference survives a fade-out")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM_LONG"), "a fade never stops the bgm player")
  Assert.equal(maxAbs(measureFade(player)), 0, "the faded bgm is silent at the target level")
end

-- The corpus uses partial fade-outs too (e.g. scr_seq_0165.s
-- "FadeOutBGM 42, 10"): the target is a level, and a fade to a nonzero
-- level leaves the BGM playing audibly at that level.
function T.fade_out_to_a_partial_level_ducks_the_bgm_but_keeps_it_audible()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  sound:fadeMusicOut({ target = 42, durationTicks = 30 })
  Assert.equal(advanceFade(sound, player, spy, 0), 0, "the fade starts from the full level")
  advanceFade(sound, player, spy, 29)
  Assert.isTrue(sound:isMusicFadeActive())
  Assert.equal(advanceFade(sound, player, spy, 1), -96, "tick N reaches the target level's ARM9 outer dB attenuation")
  Assert.isFalse(sound:isMusicFadeActive())
  Assert.isTrue(maxAbs(measureFade(player)) > 0, "the bgm stays audible at the partial target level")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM_LONG"), "the bgm player keeps playing")
end

-- FadeInBGM (GF_SndStartFadeInBGM(0x7f, length, 0) in the asm): the BGM
-- first snaps to volume zero, then ramps to full over the requested ticks.
-- The BGM is never replayed -- the fade only moves the level of the still-
-- playing player.
function T.fade_in_starts_from_silence_and_ramps_to_full_without_replaying()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  sound:fadeMusicIn({ durationTicks = 30 })
  Assert.isTrue(sound:isMusicFadeActive())
  -- tick 0: the HGSS fade-in snaps to silence first, so the audible level
  -- starts from zero even when the BGM was playing at full volume.
  Assert.equal(advanceFade(sound, player, spy, 0), -32768, "tick 0 starts from the snapped-to-zero level")
  Assert.equal(maxAbs(measureFade(player)), 0, "the snap silences the bgm at tick 0")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM_LONG"), "the fade-in never replays the bgm")
  local level15 = advanceFade(sound, player, spy, 15)
  Assert.isTrue(strictlyBetween(level15, -32768, 0), "tick N/2 carries a strictly intermediate attenuation")
  local amp15 = maxAbs(measureFade(player))
  Assert.isTrue(amp15 > 0 and amp15 < 8000, "the perceptual volume at tick N/2 is strictly between silence and full")
  local level29 = advanceFade(sound, player, spy, 14)
  Assert.isTrue(strictlyBetween(level29, level15, 0), "the attenuation keeps progressing on the last active tick")
  local amp29 = maxAbs(measureFade(player))
  Assert.isTrue(amp29 > amp15 and amp29 < 8000, "the volume keeps rising on the last active tick")
  Assert.equal(advanceFade(sound, player, spy, 1), 0, "tick N reaches the full level")
  Assert.isFalse(sound:isMusicFadeActive(), "the fade completes at exactly durationTicks updates")
  Assert.equal(maxAbs(measureFade(player)), 8000, "the bgm is back at full volume")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM_LONG"))
end

-- HGSS ignores a fade-out command while a fade is already active (the fade
-- timer is nonzero, so GF_SndStartFadeOutBGM skips the volume move): the
-- second command neither restarts the ramp nor shortens the duration.
function T.a_fade_out_is_ignored_while_a_fade_is_active()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  sound:fadeMusicOut({ target = 0, durationTicks = 10 })
  local level15 = advanceFade(sound, player, spy, 15)
  Assert.isTrue(strictlyBetween(level15, -32768, 0), "the first fade's ramp is untouched")
  Assert.isTrue(sound:isMusicFadeActive(), "the second fade-out did not restart the timer")
  advanceFade(sound, player, spy, 14)
  Assert.isTrue(sound:isMusicFadeActive(), "the fade still follows the first command's duration")
  Assert.equal(advanceFade(sound, player, spy, 1), -32768, "the fade completes on the first command's schedule")
  Assert.isFalse(sound:isMusicFadeActive())
end

-- HGSS GF_SndStartFadeInBGM has no fade-timer guard: a fade-in issued
-- while a fade is active replaces it -- the volume snaps to zero and the
-- ramp restarts with the new duration.
function T.a_fade_in_restarts_an_active_fade_from_silence()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  advanceFade(sound, player, spy, 10)
  Assert.isTrue(sound:isMusicFadeActive(), "a fade-out is in flight")
  sound:fadeMusicIn({ durationTicks = 10 })
  Assert.isTrue(sound:isMusicFadeActive(), "the fade-in replaces the active fade")
  Assert.equal(advanceFade(sound, player, spy, 0), -32768, "the fade-in snaps the level to zero")
  local level9 = advanceFade(sound, player, spy, 9)
  Assert.isTrue(strictlyBetween(level9, -32768, 0), "the new ramp progresses")
  Assert.equal(advanceFade(sound, player, spy, 1), 0, "the new fade completes on its own duration")
  Assert.isFalse(sound:isMusicFadeActive(), "the replaced fade-out's schedule is gone")
end

function T.fades_without_a_current_bgm_never_become_active()
  local sound = newGameSound()
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  Assert.isFalse(sound:isMusicFadeActive())
  sound:fadeMusicIn({ durationTicks = 30 })
  Assert.isFalse(sound:isMusicFadeActive())
end

-- HGSS DoSoundUpdateFrame only advances the fade timer while no fanfare is
-- playing: a fanfare freezes the fade at its current level and the fade
-- resumes (and completes on its original schedule) once the fanfare and its
-- post-wait are over.
function T.a_fanfare_freezes_the_active_fade_until_it_ends()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(200)
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  advanceFade(sound, player, spy, 0)
  local level10 = advanceFade(sound, player, spy, 10)
  Assert.isTrue(strictlyBetween(level10, -32768, 0), "the fade is mid-ramp")
  sound:playFanfare("SEQ_TEST_FANFARE")
  -- The fanfare sequence (duration-1 note) ends at its second tempoCounter
  -- tick (frame 750 at default tempo), so 1000 frames complete it and start
  -- the 15-frame post-wait.
  player:render(1000)
  -- The fanfare's post-wait counts down on sound frames while the fade is
  -- frozen; the bgm player is paused, so no new fader reaches its voice.
  for _ = 1, FANFARE_POST_WAIT_TICKS - 1 do
    sound:updateSoundFrame()
  end
  Assert.isTrue(sound:isFanfarePlaying(), "the fanfare is still in its post-wait")
  Assert.isTrue(sound:isMusicFadeActive(), "the fade is frozen, not completed")
  local frozen = nil
  for i = #spy.readings, 1, -1 do
    if spy.readings[i].channel == 4 then
      frozen = spy.readings[i].fader
      break
    end
  end
  Assert.equal(frozen, level10, "the fade's level does not advance while the fanfare plays")
  sound:updateSoundFrame()
  Assert.isFalse(sound:isFanfarePlaying(), "the post-wait expired")
  -- The fade resumes on its original schedule: the fanfare's ticks did not
  -- count, so it still needs 19 more updates to finish.
  advanceFade(sound, player, spy, 19)
  Assert.isFalse(sound:isMusicFadeActive(), "the fade completes only after its full original duration")
end

function T.unknown_effect_reference_faults_effect_polls()
  local sound = newGameSound()
  throwsCode("AUDIO_PROVIDER_SEQUENCE_UNKNOWN", function()
    sound:isEffectPlaying("SEQ_UNKNOWN")
  end)
end

function T.cry_without_a_cry_subsystem_fails_clearly()
  local sound = newGameSound()
  throwsCode("AUDIO_CRY_UNAVAILABLE", function()
    sound:playCry(133, 0)
  end)
  Assert.isTrue(sound:isCryFinished(), "no cry active: the wait completes")
end

function T.cry_with_a_subsystem_reports_completion()
  local played = {}
  local cryState = { finished = false }
  local cry = {
    play = function(_, species, form)
      played[#played + 1] = { species = species, form = form }
    end,
    isFinished = function()
      return cryState.finished
    end,
  }
  local sound = newGameSound(nil, { cry = cry })
  sound:playCry(133, 1)
  Assert.deepEqual(played, { { species = 133, form = 1 } })
  Assert.isFalse(sound:isCryFinished(), "the cry is still active")
  cryState.finished = true
  Assert.isTrue(sound:isCryFinished())
end

-- The retail field corpus reaches temporary music (every reference targets
-- the special scripted-music player), so the production service must
-- execute it: a public op whose only behavior is an unsupported error is
-- not part of the supported semantic surface.
function T.temporary_music_starts_the_referenced_sequence()
  local sound, player = newGameSound()
  sound:temporaryMusic("SEQ_TEST_BGM")
  Assert.isTrue(player:isPlayerPlaying(1), "temporary music starts its sequence")
end

-- The retail BGM role spans two player ids (the fixed field-music slot and
-- the special scripted-music slot), so replacing the current BGM can switch
-- active player slots: the replacement must explicitly stop the previous
-- BGM instead of relying on same-player replacement.
function T.play_music_across_player_slots_stops_the_previous_bgm()
  local bgm = seq(0, "SEQ_TEST_BGM", 1, {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  })
  local special = seq(1, "SEQ_TEST_BGM_SPECIAL", 7, {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  })
  local sound, player = newGameSound({ [0] = bgm, [1] = special })
  sound:playMusic("SEQ_TEST_BGM")
  Assert.isTrue(player:isPlayerPlaying(1), "the field BGM plays on its slot")
  sound:playMusic("SEQ_TEST_BGM_SPECIAL")
  Assert.isFalse(player:isPlayerPlaying(1), "replacing the BGM stops the previous player slot")
  Assert.isTrue(player:isPlayerPlaying(7), "the replacement plays on its own slot")
  Assert.equal(sound:currentMusic(), 1)
end

function T.reset_music_plays_the_map_header_reference()
  local sound, player = newGameSound(nil, {
    mapMusic = function()
      return "SEQ_TEST_BGM"
    end,
  })
  sound:resetMusic()
  player:render(250)
  Assert.equal(sound:currentMusic(), 0)
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"))
  Assert.isTrue(maxAbs(left(player:render(500), 500)) > 0, "the map-header music plays")
  local silent, silentPlayer = newGameSound(nil, {
    mapMusic = function()
      return nil
    end,
  })
  silent:resetMusic()
  Assert.isNil(silent:currentMusic())
  -- The released voices ring out briefly, then the mix falls silent.
  silentPlayer:render(600)
  Assert.equal(maxAbs(left(silentPlayer:render(500), 500)), 0, "no map music means silence")
end

function T.reset_music_without_a_resolver_fails_clearly()
  local sound = newGameSound()
  throwsCode("AUDIO_MAP_MUSIC_UNAVAILABLE", function()
    sound:resetMusic()
  end)
end

-- HGSS WaitSE always reads its sequence operand through ScriptGetVar
-- (scrcmd_sound.c ScrCmd_WaitSE); the project lowering always emits an
-- explicit `sound` operand for wait_sound (SemanticLowering opcode 75), so
-- no producer ever relies on an operand-less wait. The operand-less
-- "current effect" inference is invented compatibility: the wait task must
-- fault on an operand-less node without ever consulting a current-effect
-- fallback.
function T.an_operandless_wait_sound_faults_without_a_current_effect_fallback()
  local SoundWaitTask = require("libs.engine.src.script.tasks.SoundWaitTask")
  local currentEffectCalls = 0
  local audio = {
    currentEffect = function()
      currentEffectCalls = currentEffectCalls + 1
      return 5
    end,
    isEffectPlaying = function()
      return false
    end,
  }
  throwsCode("SCRIPT_TASK_UNSERIALIZABLE", function()
    SoundWaitTask.create(
      { node = { op = "wait_sound" } },
      { services = { audio = audio }, instance = { scriptId = "probe" } }
    )
  end)
  Assert.equal(currentEffectCalls, 0, "the wait never infers the effect from a current-effect fallback")
end

-- The fade ownership rule: a music fade belongs to the current BGM, so
-- stopping the BGM cancels its fade. Later fixed updates never fault
-- against the nil reference and never reactivate the fade.
function T.stopping_the_bgm_cancels_an_active_fade()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  Assert.isTrue(sound:isMusicFadeActive())
  sound:stopMusic()
  Assert.isNil(sound:currentMusic())
  Assert.isFalse(sound:isMusicFadeActive(), "stopping the bgm cancels its fade")
  for _ = 1, 40 do
    sound:updateSoundFrame()
  end
  Assert.isFalse(sound:isMusicFadeActive(), "the cancelled fade never reactivates")
  player:render(500)
end

-- The same ownership rule on replacement: a new BGM replaces the old one,
-- so the old BGM's fade is cancelled and never pushes a level to the
-- replacement.
function T.replacing_the_bgm_cancels_an_active_fade()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(200)
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  for _ = 1, 10 do
    sound:updateSoundFrame()
  end
  Assert.isTrue(sound:isMusicFadeActive(), "the fade is mid-ramp")
  sound:playMusic("SEQ_TEST_BGM_B")
  Assert.isFalse(sound:isMusicFadeActive(), "replacing the bgm cancels its fade")
  Assert.equal(sound:currentMusic(), 4)
  local readings = #spy.readings
  for _ = 1, 20 do
    sound:updateSoundFrame()
  end
  player:render(250)
  Assert.equal(#spy.readings, readings, "the cancelled fade never pushes a level to the replacement")
end

-- The fanfare completion must never resume a stale reference: a BGM
-- replaced or stopped while the fanfare plays is gone for good, and the
-- completion resumes only what is still current.
function T.fanfare_completion_never_resumes_a_replaced_or_stopped_bgm()
  local bgm = seq(0, "SEQ_TEST_BGM", 1, {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  })
  local special = seq(1, "SEQ_TEST_BGM_SPECIAL", 7, {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  })
  local fanfare = seq(2, "SEQ_TEST_FANFARE", 3, {
    { op = "program", program = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  local sound, player = newGameSound({ [0] = bgm, [1] = special, [2] = fanfare })
  sound:playMusic("SEQ_TEST_BGM")
  player:render(200)
  sound:playFanfare("SEQ_TEST_FANFARE")
  -- The BGM is replaced mid-fanfare with a sequence on a different player
  -- slot (the retail BGM role spans the fixed field-music slot and the
  -- special scripted-music slot).
  sound:playMusic("SEQ_TEST_BGM_SPECIAL")
  -- The fanfare sequence ends at its second tempoCounter tick (frame 750
  -- at default tempo).
  player:render(1000)
  for _ = 1, FANFARE_POST_WAIT_TICKS do
    sound:updateSoundFrame()
  end
  Assert.isFalse(sound:isFanfarePlaying(), "the fanfare interval expired")
  Assert.isFalse(sound:isEffectPlaying("SEQ_TEST_BGM"), "the replaced bgm is never resumed by the fanfare completion")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM_SPECIAL"), "the replacement keeps playing through the completion")
  Assert.equal(sound:currentMusic(), 1)

  -- The stop-during-fanfare path: the stopped bgm is not resumed either.
  local stopped, stoppedPlayer = newGameSound({ [0] = bgm, [2] = fanfare })
  stopped:playMusic("SEQ_TEST_BGM")
  stopped:playFanfare("SEQ_TEST_FANFARE")
  stopped:stopMusic()
  stoppedPlayer:render(1000)
  for _ = 1, FANFARE_POST_WAIT_TICKS do
    stopped:updateSoundFrame()
  end
  Assert.isFalse(stopped:isFanfarePlaying(), "the fanfare interval expired")
  Assert.isNil(stopped:currentMusic())
  Assert.isFalse(stopped:isEffectPlaying("SEQ_TEST_BGM"), "a stopped bgm is never resumed by the fanfare completion")
end

-- One applied fader authority per player: a script music fade and a generic
-- volume move on the same player cannot both own the player. The script fade
-- runs 20 frames from 127 toward 64; after 7 frames a generic move to 32 over
-- 10 frames replaces it. The replacement ramp must start from the level the
-- script fade applied after its 7th frame, reach its own target on its own
-- final frame, and end the script fade's timer -- and the player must receive
-- exactly one fader application per sound frame.
function T.an_overlapping_bgm_fade_and_generic_move_have_one_winner_and_one_current_level()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  sound:fadeMusicOut({ target = 64, durationTicks = 20 })
  -- Frames 1..7: the script fade owns the player. After 7 frames the applied
  -- level is 127 + cDiv(7 * (64 - 127), 20).
  local expected7 = 127 + NnsSoundMath.cDiv(7 * (64 - 127), 20)
  for _ = 1, 7 do
    sound:updateSoundFrame()
  end
  Assert.isTrue(sound:isMusicFadeActive(), "the script fade is mid-ramp after 7 frames")
  Assert.equal(spy.faderWrites[#spy.faderWrites].level, expected7, "the script fade owns the level after 7 frames")
  local before = #spy.faderWrites
  -- The replacement generic move starts from the applied level after frame 7.
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 32, 10)
  Assert.isFalse(sound:isMusicFadeActive(), "replacing the script fade ramp with a generic move ends the script fade")
  local writes = spy.faderWrites
  local first = before + 1
  -- The replacement ramp starts from the level the replaced ramp had applied.
  Assert.equal(writes[first].level, expected7, "the replacement ramp starts from the applied level")
  -- Frames 8..17: the replacement ramp owns the player, reaching its target
  -- exactly on its 10th frame.
  for frame = 1, 9 do
    sound:updateSoundFrame()
    Assert.equal(
      writes[first + frame].level,
      expected7 + NnsSoundMath.cDiv(frame * (32 - expected7), 10),
      "the replacement ramp owns every frame until its target"
    )
  end
  sound:updateSoundFrame()
  Assert.equal(writes[first + 10].level, 32, "the replacement ramp reaches its target on its final frame")
  Assert.isFalse(sound:isMusicFadeActive(), "the replacement ramp completed; no script fade is active")
  -- No frame ever received two fader applications for the same player.
  for i = before + 1, #writes - 1 do
    Assert.equal(writes[i].playerId, writes[i + 1].playerId, "every write is for the same player")
  end
  player:render(250)
end

-- The HGSS full-restore spelling: the pinned soundplate exit invokes
-- GF_SndHandleMoveVolume(0, 128, 15), so target 128 is a real game-level
-- source value that must normalize to the strict player full level 127 at the
-- semantic boundary and never reach the 0..127 SequencePlayer fader contract.
-- A restore from 64 to 128 over 15 frames would compute 123 on frame 14 and
-- 128 on frame 15 -- the final frame is where the out-of-range value would
-- trip the assertion, so that is the frame the scenario pins.
function T.a_source_full_restore_target_completes_without_violating_the_player_range()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  -- Duck the BGM player, then restore it with the source full-restore target.
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 64, 15)
  for _ = 1, 15 do
    sound:updateSoundFrame()
  end
  Assert.equal(spy.faderWrites[#spy.faderWrites].level, 64, "the player is ducked below full")
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 128, 15)
  -- After 14 frames the ramp is still active and has not yet reached full.
  for _ = 1, 14 do
    sound:updateSoundFrame()
  end
  Assert.equal(spy.faderWrites[#spy.faderWrites].level, 123, "the 14th restore frame is still below full")
  -- The 15th frame completes at 127 without ever pushing 128.
  sound:updateSoundFrame()
  Assert.equal(spy.faderWrites[#spy.faderWrites].level, 127, "the final frame applies the canonical full level")
  for _, write in ipairs(spy.faderWrites) do
    Assert.isTrue(
      write.level >= 0 and write.level <= 127,
      "SequencePlayer:setFader never receives a level outside 0..127"
    )
  end
  player:render(250)
end

-- A target outside the source-backed domain is a programming-contract
-- violation and fails before any state is mutated.
function T.an_out_of_range_volume_target_fails_before_mutating_state()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  local err = Assert.throws(function()
    sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 129, 15)
  end)
  Assert.isTrue(err ~= nil, "a 129 target is rejected")
  Assert.equal(sound:currentMusic(), 5, "the BGM reference is untouched by the rejected move")
  player:render(250)
end

-- Sequence replacement is a synchronization boundary: the new SequencePlayer
-- instance starts at fader 127, so GameSound's record for the player must be
-- reset to full and idle immediately, and a volume move on the replacement
-- must ramp from 127 -- never from the old sequence's ducked/partial level.
function T.a_sequence_replacement_cannot_inherit_stale_ramp_state()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  -- Duck the first BGM well below full.
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 16, 10)
  for _ = 1, 10 do
    sound:updateSoundFrame()
  end
  Assert.equal(spy.faderWrites[#spy.faderWrites].level, 16, "the first BGM is ducked")
  -- Replace it with a different BGM on the same NNS player.
  sound:playMusic("SEQ_TEST_BGM_B")
  local writes = #spy.faderWrites
  -- A volume move on the replacement ramps from the fresh instance's full
  -- level, not from the old sequence's 16.
  sound:moveSequenceVolume("SEQ_TEST_BGM_B", 64, 8)
  sound:updateSoundFrame()
  Assert.equal(
    spy.faderWrites[writes + 1].level,
    127,
    "the replacement ramp starts from full because the new instance starts at fader 127"
  )
  player:render(250)
end

-- A fade-stop owns the player's single ramp: the level interpolates to 0 over
-- the requested frames and the player is stopped only after the final ramp
-- frame has applied level 0 -- never early, never through a second engine.
function T.a_stop_with_fade_applies_level_zero_then_stops_the_player()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  sound:stopSequenceWithFade("SEQ_TEST_BGM_LONG", 10)
  -- Frames 1..9: the fade-stop owns the level and the player keeps playing.
  for frame = 1, 9 do
    sound:updateSoundFrame()
    Assert.equal(spy.faderWrites[#spy.faderWrites].level, 127 + NnsSoundMath.cDiv(frame * (0 - 127), 10))
    Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM_LONG"), "the player still plays before the final frame")
  end
  -- Frame 10: level 0 is applied before the player stops.
  sound:updateSoundFrame()
  Assert.equal(spy.faderWrites[#spy.faderWrites].level, 0, "the final ramp frame applies level 0")
  Assert.isFalse(sound:isEffectPlaying("SEQ_TEST_BGM_LONG"), "the player stops only after the final frame")
  player:render(250)
end

-- A stop-after-fade must never stop the player early: after duration-1 frames
-- the stop happens exactly on the frame that reaches level 0, and a later
-- update finds the player already stopped with no further writes.
function T.a_stop_with_fade_of_one_frame_stops_after_the_single_level_zero_frame()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  sound:stopSequenceWithFade("SEQ_TEST_BGM_LONG", 1)
  local writes = #spy.faderWrites
  sound:updateSoundFrame()
  Assert.equal(spy.faderWrites[writes + 1].level, 0, "the single frame applies level 0")
  Assert.isFalse(sound:isEffectPlaying("SEQ_TEST_BGM_LONG"), "the player stopped on the level-zero frame")
  sound:updateSoundFrame()
  Assert.equal(#spy.faderWrites, writes + 1, "no fader is applied after the player stopped")
end

-- Exact integer interpolation for a rising ramp and for a falling ramp of
-- duration 1, using the source cDiv formula.
function T.ramps_interpolate_exactly_with_cdiv_for_rising_and_falling_levels()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  -- Rising: from 64 back toward full over 3 frames.
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 64, 3)
  for _ = 1, 3 do
    sound:updateSoundFrame()
  end
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 127, 3)
  for frame = 1, 3 do
    sound:updateSoundFrame()
    Assert.equal(
      spy.faderWrites[#spy.faderWrites].level,
      64 + NnsSoundMath.cDiv(frame * (127 - 64), 3),
      "rising ramp follows the source cDiv interpolation"
    )
  end
  -- Duration 1: the single frame lands exactly on the target.
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 30, 1)
  sound:updateSoundFrame()
  Assert.equal(spy.faderWrites[#spy.faderWrites].level, 30, "a duration-1 ramp reaches its target on its only frame")
  player:render(250)
end

-- Replacing a ramp while it is mid-flight starts from the level the replaced
-- ramp has already applied (the record's current level), never from the
-- original ramp's start or a stale field.
function T.replacing_a_mid_ramp_starts_from_the_current_applied_level()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 64, 20)
  sound:updateSoundFrame()
  sound:updateSoundFrame()
  local expected2 = 127 + NnsSoundMath.cDiv(2 * (64 - 127), 20)
  Assert.equal(spy.faderWrites[#spy.faderWrites].level, expected2, "the first ramp applied its 2nd-frame level")
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 32, 10)
  sound:updateSoundFrame()
  Assert.equal(
    spy.faderWrites[#spy.faderWrites].level,
    expected2 + NnsSoundMath.cDiv(1 * (32 - expected2), 10),
    "the replacement starts from the level the replaced ramp applied"
  )
  player:render(250)
end

-- Invalid durations are programming-contract violations and fail before any
-- ramp state is created.
function T.invalid_fader_durations_fail_before_mutating_state()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  Assert.throws(function()
    sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 64, 0)
  end)
  Assert.throws(function()
    sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 64, 10.5)
  end)
  Assert.throws(function()
    sound:stopSequenceWithFade("SEQ_TEST_BGM_LONG", 0)
  end)
  -- No ramp was created: a subsequent valid move starts from full.
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 90, 1)
  local writes = #spy.faderWrites
  sound:updateSoundFrame()
  Assert.equal(spy.faderWrites[writes + 1].level, 90, "the player level was untouched by the rejected calls")
  player:render(250)
end

-- The fanfare freeze is a property of the script music fade: while a fanfare
-- plays, an existing script-music fade ramp is frozen and resumes after the
-- fanfare completes, exactly as the HGSS DoSoundUpdateFrame ordering requires.
-- A generic ramp is not auto-frozen: it keeps interpolating from its own
-- start through the fanfare.
function T.a_generic_ramp_is_not_frozen_by_a_fanfare()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 32, 20)
  -- Frame 1 of the generic ramp, then a fanfare starts.
  sound:updateSoundFrame()
  local level1 = spy.faderWrites[#spy.faderWrites].level
  Assert.equal(level1, 127 + NnsSoundMath.cDiv(1 * (32 - 127), 20), "the generic ramp applied its first frame")
  sound:playFanfare("SEQ_TEST_FANFARE")
  player:render(500)
  Assert.isTrue(sound:isFanfarePlaying(), "the fanfare is in flight")
  -- The generic ramp keeps advancing through the fanfare: it is not the
  -- script music fade that the HGSS freeze protects, so its second frame
  -- applies from its own start and never sits frozen at frame 1.
  sound:updateSoundFrame()
  Assert.equal(
    spy.faderWrites[#spy.faderWrites].level,
    127 + NnsSoundMath.cDiv(2 * (32 - 127), 20),
    "the generic ramp advances during the fanfare"
  )
  player:render(250)
end

-- Deterministic iteration: when two players have ramps completing on the same
-- sound frame, both are applied in ascending player-id order and a stop is
-- issued for the player whose ramp requested it.
function T.ramps_on_multiple_players_advance_in_deterministic_player_order()
  local bgm = seq(0, "SEQ_TEST_BGM", 1, {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  })
  local effect = seq(1, "SEQ_TEST_EFFECT", 2, {
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 4 },
    { op = "end" },
  })
  local sound, player, spy = newGameSound({ [0] = bgm, [1] = effect })
  sound:playMusic("SEQ_TEST_BGM")
  sound:play("SEQ_TEST_EFFECT")
  player:render(250)
  sound:moveSequenceVolume("SEQ_TEST_BGM", 64, 3)
  sound:stopSequenceWithFade("SEQ_TEST_EFFECT", 3)
  -- One frame advances both players; the lower player id is written first.
  sound:updateSoundFrame()
  Assert.equal(spy.faderWrites[#spy.faderWrites - 1].playerId, 1)
  Assert.equal(spy.faderWrites[#spy.faderWrites].playerId, 2)
  -- The two remaining frames complete both ramps and stop the effect player.
  sound:updateSoundFrame()
  sound:updateSoundFrame()
  Assert.equal(spy.faderWrites[#spy.faderWrites].playerId, 2)
  Assert.isFalse(sound:isEffectPlaying("SEQ_TEST_EFFECT"), "the fade-stop stopped its player")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the volume move left its player playing")
  player:render(250)
end

-- After a full-restore ramp completes, the player record keeps the level that
-- was actually applied (127), never the raw source target 128 -- so a later
-- move on the same player ramps from the applied full level, and the record
-- always equals what SequencePlayer holds.
function T.after_a_full_restore_the_record_holds_the_applied_level_not_raw_128()
  local sound, player, spy = newGameSound()
  sound:playMusic("SEQ_TEST_BGM_LONG")
  player:render(250)
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 128, 15)
  for _ = 1, 15 do
    sound:updateSoundFrame()
  end
  Assert.equal(spy.faderWrites[#spy.faderWrites].level, 127, "the full restore applied 127")
  -- A move issued after the restore ramps from 127, not from a stale 128.
  sound:moveSequenceVolume("SEQ_TEST_BGM_LONG", 64, 4)
  sound:updateSoundFrame()
  Assert.equal(
    spy.faderWrites[#spy.faderWrites].level,
    127 + NnsSoundMath.cDiv(1 * (64 - 127), 4),
    "the follow-up ramp starts from the applied full level"
  )
  player:render(250)
end

return { tests = T }
