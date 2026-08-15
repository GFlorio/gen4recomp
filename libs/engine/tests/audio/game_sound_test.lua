-- GameSound contract: the semantic audio facade field scripts receive as
-- their `audio` service. It wraps the real engine audio (AudioAssetProvider
-- + SequencePlayer + VoiceMixer) and owns the script-observable semantics:
-- BGM (play/stop/replace/current), effects (play/stop; waits follow the
-- HGSS IsSEPlaying model -- the wait sequence is always resolved from the
-- script operand, never from a "current effect" inference), the fanfare
-- state machine (HGSS PlayFanfare PAUSES the BGM player -- the sequence
-- stays held and resumes at its preserved position after the fanfare and
-- its 15-tick post-wait; a fanfare never stops and replays the BGM), fixed-
-- tick fades (the HGSS GF_SndStartFadeOutBGM/FadeInBGM model: the fade
-- state carries starting level/target/total/elapsed, the level ramps
-- linearly per tick into a dB-domain attenuation the mixer applies through
-- its per-voice fader hook, a fade-out while one is active is skipped while
-- a fade-in restarts from silence, a fade never stops the BGM player, and
-- the fade timer is frozen while a fanfare is active per DoSoundUpdateFrame),
-- the cry boundary (a reachable cry without a cry subsystem is an attributed
-- failure until a cry data path exists), and the save-stability predicate
-- (always true: every script wait on transient audio -- fades, fanfares,
-- cries, awaited effects -- persists as task state and completes immediately
-- against the fresh audio service built at load, so no capture bisects a
-- persisted game-semantic operation and a looping effect can never hold a
-- save hostage). PCM rendering is the output sink's business: GameSound never
-- renders. All polls return booleans, never nil. The only injectable
-- boundaries are the cry subsystem and the map-music resolver; everything
-- else runs the real engine audio.

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
        heapSize = 0x2000,
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

local function zeros(frames)
  local out = {}
  for i = 1, frames do
    out[i] = 0
  end
  return out
end

-- The looping pattern `wave` renders over `frames` frames at pitch ratio 1.
local function wavePattern(wave, frames)
  local out = {}
  for i = 1, frames do
    out[i] = wave[(i - 1) % #wave + 1]
  end
  return out
end

-- BGM (WAVE_A) and an effect (WAVE_B) mixing on two players, frame by frame.
local function mixedAB(frames)
  local out = {}
  for i = 1, frames do
    out[i] = WAVE_A[(i - 1) % #WAVE_A + 1] + WAVE_B[(i - 1) % #WAVE_B + 1]
  end
  return out
end

-- The expected-PCM model (release cadence) is shared with the
-- sequence-player suite; see tests/support/AudioPattern.lua.
local AudioPattern = require("tests.support.AudioPattern")
local waveAt = AudioPattern.waveAt
local segment = AudioPattern.segment
local sumSegments = AudioPattern.sumSegments
local slice = AudioPattern.slice

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
  Assert.isTrue(sound:isSaveStable(), "silence is stable")
  sound:playMusic("SEQ_TEST_BGM")
  Assert.equal(sound:currentMusic(), 0, "currentMusic is the resolved sequence id")
  Assert.deepEqual(left(player:render(500), 500), wavePattern(WAVE_A, 500), "the bgm plays")
  Assert.isTrue(sound:isSaveStable(), "ordinary continuous map bgm is stable")
  sound:stopMusic()
  Assert.isNil(sound:currentMusic())
  -- The tick at frame 500 retriggers the looping bgm's note before
  -- stopMusic runs, so the ring-out is the old voice plus the retriggered
  -- voice (both released at frame 500).
  local after = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 1, 1, 1000, 500),
    segment(waveAt(WAVE_A, 1, 501), 1, 501, 1000, 500),
  }, 1000)
  Assert.deepEqual(
    left(player:render(500), 500),
    slice(after, 501, 1000),
    "stopMusic releases the voices: they ring to the next control step, then the release tail"
  )
  Assert.isTrue(sound:isSaveStable())
end

function T.play_music_replaces_the_running_bgm_on_its_player()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  player:render(100)
  sound:playMusic("SEQ_TEST_BGM_B")
  Assert.equal(sound:currentMusic(), 4)
  local after = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 1, 1, 600, 100),
    segment(waveAt(WAVE_B, 1, 101), 1, 101, 600),
  }, 600)
  Assert.deepEqual(
    left(player:render(500), 500),
    slice(after, 101, 600),
    "the released bgm rings its release tail under the replacement"
  )
end

function T.effects_overlap_bgm_and_report_player_completion()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:play(1)
  Assert.isTrue(sound:isEffectPlaying(1), "the effect is playing on its player")
  Assert.isTrue(sound:isSaveStable(), "an awaited effect never blocks saving: transient audio is discarded on load")
  local pcm = player:render(600)
  Assert.deepEqual(left(pcm, 500), mixedAB(500), "the effect overlaps the bgm")
  -- The tick at frame 500 releases both notes; their release lag and tail
  -- overlap the bgm's retrigger at frame 501.
  local expected = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 1, 1, 600, 500),
    segment(waveAt(WAVE_A, 1, 501), 1, 501, 600),
    segment(waveAt(WAVE_B, 1, 1), 1, 1, 600, 500),
  }, 600)
  Assert.deepEqual(
    slice(expected, 501, 600),
    slice(left(pcm, 600), 501, 600),
    "the release tails overlap the retrigger"
  )
  Assert.isFalse(sound:isEffectPlaying(1), "the effect completed; the bgm player is untouched")
  Assert.isTrue(sound:isSaveStable())
end

-- The HGSS wait model (IsSEPlaying): resolve the sequence's player and test
-- that player's playback state, not an individual host-source token. The
-- still-playing poll lands inside the note's window: the engine processes
-- the gate-release tick after the boundary frame's render, so a duration-2
-- effect is audible through frame 1000 and its player reports free right
-- after that render returns (the same boundary the player suite pins at
-- 500 frames for a 1-tick note).
function T.effect_waits_follow_the_sequence_player_state()
  local sound, player = newGameSound()
  Assert.isFalse(sound:isEffectPlaying(1), "never-played effects report not playing")
  sound:play(1)
  sound:play(3)
  Assert.isTrue(sound:isEffectPlaying(1), "a later effect on the same player keeps the player busy")
  -- The replaced effect rings its release tail under the replacement.
  local expected = sumSegments({
    segment(waveAt(WAVE_B, 1, 1), 1, 1, 1500, 0),
    segment(waveAt(WAVE_B, 1, 1), 1, 1, 1500, 1000),
  }, 1500)
  Assert.deepEqual(
    left(player:render(500), 500),
    slice(expected, 1, 500),
    "the replacement effect rings over the released effect's tail"
  )
  Assert.isTrue(sound:isEffectPlaying(1), "the replacement effect keeps its player busy through its window")
  Assert.deepEqual(
    left(player:render(500), 500),
    slice(expected, 501, 1000),
    "the replacement effect plays its full duration"
  )
  player:render(200)
  Assert.isFalse(sound:isEffectPlaying(1), "the player's sequence ended")
  Assert.isFalse(sound:isEffectPlaying(3))
end

function T.stop_effect_stops_only_its_player()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:play(1)
  player:render(200)
  Assert.deepEqual(left(player:render(200), 200), mixedAB(200), "bgm and effect are both audible")
  sound:stop(1)
  Assert.isFalse(sound:isEffectPlaying(1))
  -- The stopped effect rings its release tail while the bgm keeps looping
  -- (its own tick release overlaps the retrigger at frame 501).
  local expected = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 1, 1, 900, 500),
    segment(waveAt(WAVE_A, 1, 501), 1, 501, 900),
    segment(waveAt(WAVE_B, 1, 1), 1, 1, 900, 400),
  }, 900)
  Assert.deepEqual(left(player:render(500), 500), slice(expected, 401, 900), "the bgm survives the effect stop")
end

-- The fanfare state machine, per the HGSS PlayFanfare path (asm/unk_02005D10.s
-- PlayFanfare/IsFanfarePlaying + sound.c): the BGM player is PAUSED through
-- NNS_SndPlayerPause -- its sequence stays held and its sample position is
-- frozen -- the fanfare plays on its own player, the 15-tick post-wait
-- holds, then the same player resumes at its preserved position. A fanfare
-- never stops the BGM player and never replays it from the start.
function T.fanfare_pauses_the_bgm_player_and_resumes_at_its_preserved_position()
  local sound, player = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  player:render(200)
  sound:playFanfare("SEQ_TEST_FANFARE")
  Assert.isTrue(sound:isFanfarePlaying())
  Assert.isTrue(sound:isSaveStable(), "a fanfare never blocks saving: transient audio is discarded on load")
  -- The BGM player is paused, not stopped: its sequence is still held.
  Assert.isTrue(sound:isEffectPlaying("SEQ_TEST_BGM"), "the bgm player is paused, not stopped, during the fanfare")
  -- The paused bgm is silent; only the fanfare sounds (its note expires at
  -- the tick at frame 700 and rings at full gain through the release lag).
  local during = segment(waveAt(WAVE_C, 1, 201), 1, 201, 700, 700)
  Assert.deepEqual(
    left(player:render(500), 500),
    slice(during, 201, 700),
    "the fanfare plays alone; the paused bgm contributes no release tail"
  )
  Assert.isTrue(sound:isFanfarePlaying(), "the post-fanfare wait interval is still fanfare-playing")
  Assert.isTrue(sound:isSaveStable(), "the fanfare never blocks saving, mid-interval too")
  for _ = 1, FANFARE_POST_WAIT_TICKS - 1 do
    sound:updateFixed()
  end
  Assert.isTrue(sound:isFanfarePlaying(), "the interval holds for its full length")
  local held = segment(waveAt(WAVE_C, 1, 201), 1, 201, 800, 700)
  Assert.deepEqual(
    left(player:render(100), 100),
    slice(held, 701, 800),
    "the fanfare's release rings through the interval; the bgm stays suspended"
  )
  sound:updateFixed()
  Assert.isFalse(sound:isFanfarePlaying(), "the interval expired")
  -- The resumed bgm continues at its preserved position: frame 801 reads
  -- the sample the paused note had reached (phaseOffset 200), the note's
  -- gate expires at the original tick at frame 1100, and the retriggered
  -- note starts at 1101 -- the fanfare neither restarted the sample nor
  -- shifted the loop timeline.
  local resumed = sumSegments({
    segment(waveAt(WAVE_C, 1, 201), 1, 201, 1300, 700),
    segment(waveAt(WAVE_A, 1, 801, 200), 1, 801, 1300, 1100),
    segment(waveAt(WAVE_A, 1, 1101), 1, 1101, 1300),
  }, 1300)
  Assert.deepEqual(
    left(player:render(500), 500),
    slice(resumed, 801, 1300),
    "the bgm resumes at its preserved position on its original timeline"
  )
  Assert.isTrue(sound:isSaveStable())
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
  Assert.isTrue(sound:isSaveStable(), "a music fade never blocks saving: transient audio is discarded on load")
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
  Assert.isTrue(sound:isSaveStable(), "the fade never blocks saving, completed or active")
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
  Assert.isTrue(sound:isSaveStable())
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

function T.cry_with_a_subsystem_reports_completion_and_stability()
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
  Assert.isTrue(sound:isSaveStable(), "an active cry never blocks saving: transient audio is discarded on load")
  cryState.finished = true
  Assert.isTrue(sound:isCryFinished())
  Assert.isTrue(sound:isSaveStable())
end

function T.temporary_music_fails_clearly()
  local sound = newGameSound()
  throwsCode("AUDIO_TEMPORARY_MUSIC_UNSUPPORTED", function()
    sound:temporaryMusic("SEQ_TEST_BGM")
  end)
end

function T.reset_music_plays_the_map_header_reference()
  local sound, player = newGameSound(nil, {
    mapMusic = function()
      return "SEQ_TEST_BGM"
    end,
  })
  sound:resetMusic()
  Assert.equal(sound:currentMusic(), 0)
  Assert.deepEqual(left(player:render(500), 500), wavePattern(WAVE_A, 500), "the map-header music plays")
  local silent, silentPlayer = newGameSound(nil, {
    mapMusic = function()
      return nil
    end,
  })
  silent:resetMusic()
  Assert.isNil(silent:currentMusic())
  Assert.deepEqual(left(silentPlayer:render(500), 500), zeros(500), "no map music means silence")
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

return { tests = T }
