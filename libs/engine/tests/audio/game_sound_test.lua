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
local AudioCache = require("libs.assets.src.AudioCache")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local GameSound = require("libs.engine.src.audio.GameSound")

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
      file = AudioCache.sequencePath(id),
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
  indexBanks[12] = { id = 12, symbol = "BANK_TEST", file = AudioCache.bankPath(12) }
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
  local spy = { readings = {} }
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
    sound:updateFixed()
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
  player:render(100)
  sound:playMusic("SEQ_TEST_BGM_B")
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
  player:render(500)
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
  player:render(200)
  sound:playFanfare("SEQ_TEST_FANFARE")
  Assert.isTrue(sound:isFanfarePlaying())
  -- The BGM player is paused, not stopped: its sequence is still held.
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the bgm player is paused, not stopped, during the fanfare")
  -- The fanfare plays through the pause.
  Assert.isTrue(maxAbs(left(player:render(500), 500)) > 0, "the fanfare plays while the bgm timeline is paused")
  Assert.isTrue(sound:isFanfarePlaying(), "the post-fanfare wait interval is still fanfare-playing")
  for _ = 1, FANFARE_POST_WAIT_TICKS - 1 do
    sound:updateFixed()
  end
  Assert.isTrue(sound:isFanfarePlaying(), "the interval holds for its full length")
  sound:updateFixed()
  Assert.isFalse(sound:isFanfarePlaying(), "the interval expired")
  -- The still-current bgm's timeline resumes from its paused position and
  -- its loop renders again; the released voice is never resurrected.
  Assert.equal(sound:currentMusic(), 0, "the fanfare never stops the bgm reference")
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the resumed bgm player still plays")
  Assert.isTrue(maxAbs(left(player:render(500), 500)) > 0, "the resumed bgm renders again")
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
  player:render(200)
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
  player:render(200)
  sound:fadeMusicOut({ target = 42, durationTicks = 30 })
  Assert.equal(advanceFade(sound, player, spy, 0), 0, "the fade starts from the full level")
  advanceFade(sound, player, spy, 29)
  Assert.isTrue(sound:isMusicFadeActive())
  Assert.equal(advanceFade(sound, player, spy, 1), -192, "tick N reaches the target level's dB attenuation")
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
  player:render(200)
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
  player:render(500)
  -- The fanfare's post-wait counts down on field ticks while the fade is
  -- frozen; the bgm player is paused, so no new fader reaches its voice.
  for _ = 1, FANFARE_POST_WAIT_TICKS - 1 do
    sound:updateFixed()
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
  sound:updateFixed()
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
    sound:updateFixed()
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
    sound:updateFixed()
  end
  Assert.isTrue(sound:isMusicFadeActive(), "the fade is mid-ramp")
  sound:playMusic("SEQ_TEST_BGM_B")
  Assert.isFalse(sound:isMusicFadeActive(), "replacing the bgm cancels its fade")
  Assert.equal(sound:currentMusic(), 4)
  local readings = #spy.readings
  for _ = 1, 20 do
    sound:updateFixed()
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
  player:render(500)
  for _ = 1, FANFARE_POST_WAIT_TICKS do
    sound:updateFixed()
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
  stoppedPlayer:render(500)
  for _ = 1, FANFARE_POST_WAIT_TICKS do
    stopped:updateFixed()
  end
  Assert.isFalse(stopped:isFanfarePlaying(), "the fanfare interval expired")
  Assert.isNil(stopped:currentMusic())
  Assert.isFalse(stopped:isEffectPlaying("SEQ_TEST_BGM"), "a stopped bgm is never resumed by the fanfare completion")
end

return { tests = T }
