-- GameSound contract: the semantic audio facade scripts receive. It wraps
-- the real engine audio (AudioAssetProvider + SequencePlayer + VoiceMixer)
-- and owns the script-observable semantics: BGM (play/stop/replace/current),
-- effects (play/stop, player-state waits per the HGSS IsSEPlaying model),
-- the fanfare state machine (pause BGM, play on its own player, post-fanfare
-- wait interval, resume BGM), fixed-tick fades, the cry boundary (a reachable
-- cry without a cry subsystem fails clearly), and the save-stability
-- predicate. All polls return booleans, never nil. The only injectable
-- boundaries are the cry subsystem (not yet built) and the map-music resolver
-- (field policy owner); everything else runs the real engine audio.

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
  return AudioFixture.bank(12, "BANK_TEST", nil, { AudioFixture.key(1), AudioFixture.key(2), AudioFixture.key(3) }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
    [2] = { kind = "direct", voice = voice(AudioFixture.key(3)) },
  })
end

local function seq(id, symbol, playerId, instructions)
  return AudioFixture.sequence(id, symbol, 12, playerId, { entry = 1, instructions = instructions }, {
    id = playerId,
    initialVolume = 127,
    channelPriority = 64,
    playerPriority = 64,
  })
end

-- The synthetic archive the facade plays: a looping BGM on player 1, a
-- finite effect and a second finite effect (longer, same player) on player
-- 2, the fanfare on player 3, and a second looping BGM on player 1.
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
  }
end

local function engineBundle(sequences)
  local keyA, keyB, keyC = AudioFixture.key(1), AudioFixture.key(2), AudioFixture.key(3)
  local bundle = AudioFixture.bundle()
  local indexSequences, indexPlayers, indexBanks, bySymbol = {}, {}, {}, {}
  for id, sequence in pairs(sequences) do
    indexSequences[id] = {
      id = id,
      symbol = sequence.symbol,
      file = AudioCache.sequencePath(id),
      bankId = sequence.bankId,
      playerId = sequence.player.id,
    }
    bySymbol[sequence.symbol] = id
    if indexPlayers[sequence.player.id] == nil then
      indexPlayers[sequence.player.id] = {
        id = sequence.player.id,
        maxSequences = 16,
        channelMask = 0xFFFF,
        heapSize = 0x2000,
      }
    end
  end
  indexBanks[12] = { id = 12, symbol = "BANK_TEST", file = AudioCache.bankPath(12), waveArchives = {} }
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = indexBanks
  bundle.index.bySymbol = bySymbol
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
-- (cry subsystem, map-music resolver) are injectable.
local function newGameSound(sequences, opts)
  opts = opts or {}
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(engineBundle(sequences or defaultSequences())))
  local player = SequencePlayer.new({
    sampleRate = SAMPLE_RATE,
    mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE }),
    provider = provider,
  })
  local sound = GameSound.new({
    provider = provider,
    player = player,
    cry = opts.cry,
    mapMusic = opts.mapMusic,
  })
  return sound
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

-- The post-fanfare wait interval in field ticks: the HGSS fanfare machine
-- counts down a u16 timer set to 0x0F at PlayFanfare (PlayFanfare -> the
-- timer-set helper in the sound code), decremented once the fanfare player
-- stops, before BGM resumes.
local FANFARE_POST_WAIT_TICKS = 15

function T.bgm_plays_tracks_current_music_and_stops()
  local sound = newGameSound()
  Assert.isTrue(sound:isSaveStable(), "silence is stable")
  sound:playMusic("SEQ_TEST_BGM")
  Assert.equal(sound:currentMusic(), 0, "currentMusic is the resolved sequence id")
  Assert.deepEqual(left(sound:render(500), 500), wavePattern(WAVE_A, 500), "the bgm plays")
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
    left(sound:render(500), 500),
    slice(after, 501, 1000),
    "stopMusic releases the voices: they ring to the next control step, then the release tail"
  )
  Assert.isTrue(sound:isSaveStable())
end

function T.play_music_replaces_the_running_bgm_on_its_player()
  local sound = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:render(100)
  sound:playMusic("SEQ_TEST_BGM_B")
  Assert.equal(sound:currentMusic(), 4)
  local after = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 1, 1, 600, 100),
    segment(waveAt(WAVE_B, 1, 101), 1, 101, 600),
  }, 600)
  Assert.deepEqual(
    left(sound:render(500), 500),
    slice(after, 101, 600),
    "the released bgm rings its release tail under the replacement"
  )
end

function T.effects_overlap_bgm_and_report_player_completion()
  local sound = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:play(1)
  Assert.isTrue(sound:isEffectPlaying(1), "the effect is playing on its player")
  Assert.isFalse(sound:isSaveStable(), "an effect that can be awaited blocks saving")
  local pcm = sound:render(600)
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
  local sound = newGameSound()
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
    left(sound:render(500), 500),
    slice(expected, 1, 500),
    "the replacement effect rings over the released effect's tail"
  )
  Assert.isTrue(sound:isEffectPlaying(1), "the replacement effect keeps its player busy through its window")
  Assert.deepEqual(
    left(sound:render(500), 500),
    slice(expected, 501, 1000),
    "the replacement effect plays its full duration"
  )
  sound:render(200)
  Assert.isFalse(sound:isEffectPlaying(1), "the player's sequence ended")
  Assert.isFalse(sound:isEffectPlaying(3))
end

function T.stop_effect_stops_only_its_player()
  local sound = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:play(1)
  sound:render(200)
  Assert.deepEqual(left(sound:render(200), 200), mixedAB(200), "bgm and effect are both audible")
  sound:stop(1)
  Assert.isFalse(sound:isEffectPlaying(1))
  -- The stopped effect rings its release tail while the bgm keeps looping
  -- (its own tick release overlaps the retrigger at frame 501).
  local expected = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 1, 1, 900, 500),
    segment(waveAt(WAVE_A, 1, 501), 1, 501, 900),
    segment(waveAt(WAVE_B, 1, 1), 1, 1, 900, 400),
  }, 900)
  Assert.deepEqual(left(sound:render(500), 500), slice(expected, 401, 900), "the bgm survives the effect stop")
end

function T.current_effect_returns_the_most_recent_effect()
  local sound = newGameSound()
  Assert.isNil(sound:currentEffect())
  sound:play(1)
  Assert.equal(sound:currentEffect(), 1)
  sound:play(3)
  Assert.equal(sound:currentEffect(), 3)
end

-- The fanfare state machine: pause BGM, play through the fanfare's own
-- player, wait for playback, hold the post-fanfare interval on field ticks,
-- then resume the prior BGM.
function T.fanfare_pauses_bgm_plays_and_resumes_after_the_post_wait()
  local sound = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:render(200)
  sound:playFanfare("SEQ_TEST_FANFARE")
  Assert.isTrue(sound:isFanfarePlaying())
  Assert.isFalse(sound:isSaveStable(), "a fanfare blocks saving")
  -- The paused bgm rings its release tail under the fanfare; the fanfare
  -- note (dur 1, started at frame 201) expires at the next tick (frame 500).
  local during = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 1, 1, 700, 200),
    segment(waveAt(WAVE_C, 1, 201), 1, 201, 700, 500),
  }, 700)
  Assert.deepEqual(
    left(sound:render(500), 500),
    slice(during, 201, 700),
    "the fanfare plays while the paused bgm's release tail rings out"
  )
  Assert.isTrue(sound:isFanfarePlaying(), "the post-fanfare wait interval is still fanfare-playing")
  Assert.isFalse(sound:isSaveStable())
  for _ = 1, FANFARE_POST_WAIT_TICKS - 1 do
    sound:updateFixed()
  end
  Assert.isTrue(sound:isFanfarePlaying(), "the interval holds for its full length")
  local held = sumSegments({ segment(waveAt(WAVE_C, 1, 201), 1, 201, 800, 500) }, 800)
  Assert.deepEqual(
    left(sound:render(100), 100),
    slice(held, 701, 800),
    "the fanfare's release rings through the interval; the bgm stays suspended"
  )
  sound:updateFixed()
  Assert.isFalse(sound:isFanfarePlaying(), "the interval expired")
  -- The resumed bgm starts fresh at 801; the fanfare's own release tail
  -- (it expired at frame 500) still rings through frame 1000, so the
  -- resumed window sums the fanfare tail under the bgm.
  local resumed = sumSegments({
    segment(waveAt(WAVE_C, 1, 201), 1, 201, 1300, 500),
    segment(waveAt(WAVE_A, 1, 801), 1, 801, 500),
  }, 1300)
  Assert.deepEqual(left(sound:render(500), 500), slice(resumed, 801, 1300), "the prior bgm resumes")
  Assert.isTrue(sound:isSaveStable())
end

-- Fades advance on game-level fixed ticks (updateFixed), never on render
-- cadence; the fade-out to target 0 ends with the bgm stopped but the
-- current-music reference retained for a later fade-in.
function T.fade_out_takes_exactly_duration_ticks_then_stops_the_bgm()
  local sound = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:render(200)
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  Assert.isTrue(sound:isMusicFadeActive())
  Assert.isFalse(sound:isSaveStable(), "a music fade blocks saving")
  for _ = 1, 29 do
    sound:updateFixed()
  end
  Assert.isTrue(sound:isMusicFadeActive(), "the fade holds through durationTicks-1 updates")
  sound:updateFixed()
  Assert.isFalse(sound:isMusicFadeActive())
  -- The stopped bgm rings its release tail (the note had played 200 frames;
  -- the stop lands at absolute frame 200, so the release lag runs to the
  -- next control step at frame 250).
  local after = sumSegments({ segment(waveAt(WAVE_A, 1, 1), 1, 201, 500, 200) }, 700)
  Assert.deepEqual(
    left(sound:render(500), 500),
    slice(after, 201, 700),
    "the fade-out stopped the bgm; its release tail rings out"
  )
  Assert.equal(sound:currentMusic(), 0, "the current-music reference survives for fade-in")
  Assert.isTrue(sound:isSaveStable())
end

function T.fade_in_restores_the_current_bgm_after_its_ticks()
  local sound = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:render(200)
  sound:fadeMusicOut({ target = 0, durationTicks = 10 })
  for _ = 1, 10 do
    sound:updateFixed()
  end
  sound:fadeMusicIn({ durationTicks = 10 })
  Assert.isTrue(sound:isMusicFadeActive())
  for _ = 1, 9 do
    sound:updateFixed()
  end
  Assert.isTrue(sound:isMusicFadeActive())
  sound:updateFixed()
  Assert.isFalse(sound:isMusicFadeActive())
  -- The resumed bgm's first frames sum two voices: the old note (released
  -- at frame 200 when the fade-out stopped the bgm) rings its tail while
  -- the restarted note begins at frame 201.
  local resumed = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 1, 1, 700, 200),
    segment(waveAt(WAVE_A, 1, 201), 1, 201, 700),
  }, 700)
  Assert.deepEqual(left(sound:render(500), 500), slice(resumed, 201, 700), "the current bgm plays again")
end

-- HGSS ignores a fade command while a fade is already active (the fade
-- timer is nonzero), and a fade with no current bgm never starts at all.
function T.a_fade_is_ignored_while_one_is_active()
  local sound = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  sound:fadeMusicOut({ target = 0, durationTicks = 10 })
  for _ = 1, 29 do
    sound:updateFixed()
  end
  Assert.isTrue(sound:isMusicFadeActive(), "the second fade did not restart the timer")
  sound:updateFixed()
  Assert.isFalse(sound:isMusicFadeActive())
end

function T.fades_without_a_current_bgm_never_become_active()
  local sound = newGameSound()
  sound:fadeMusicOut({ target = 0, durationTicks = 30 })
  Assert.isFalse(sound:isMusicFadeActive())
  sound:fadeMusicIn({ durationTicks = 30 })
  Assert.isFalse(sound:isMusicFadeActive())
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
  Assert.isFalse(sound:isSaveStable(), "an active cry blocks saving")
  cryState.finished = true
  Assert.isTrue(sound:isCryFinished())
  Assert.isTrue(sound:isSaveStable())
end

function T.temporary_music_fails_clearly_until_the_scene_flow_lands()
  local sound = newGameSound()
  throwsCode("AUDIO_TEMPORARY_MUSIC_UNSUPPORTED", function()
    sound:temporaryMusic("SEQ_TEST_BGM")
  end)
end

function T.reset_music_plays_the_map_header_reference()
  local sound = newGameSound(nil, {
    mapMusic = function()
      return "SEQ_TEST_BGM"
    end,
  })
  sound:resetMusic()
  Assert.equal(sound:currentMusic(), 0)
  Assert.deepEqual(left(sound:render(500), 500), wavePattern(WAVE_A, 500), "the map-header music plays")
  local silent = newGameSound(nil, {
    mapMusic = function()
      return nil
    end,
  })
  silent:resetMusic()
  Assert.isNil(silent:currentMusic())
  Assert.deepEqual(left(silent:render(500), 500), zeros(500), "no map music means silence")
end

function T.reset_music_without_a_resolver_fails_clearly()
  local sound = newGameSound()
  throwsCode("AUDIO_MAP_MUSIC_UNAVAILABLE", function()
    sound:resetMusic()
  end)
end

return { tests = T }
