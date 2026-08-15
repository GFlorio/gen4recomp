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
    rootKey = 60,
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
  Assert.deepEqual(left(sound:render(500), 500), zeros(500), "stopMusic silences the bgm")
  Assert.isTrue(sound:isSaveStable())
end

function T.play_music_replaces_the_running_bgm_on_its_player()
  local sound = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:render(100)
  sound:playMusic("SEQ_TEST_BGM_B")
  Assert.equal(sound:currentMusic(), 4)
  Assert.deepEqual(left(sound:render(500), 500), wavePattern(WAVE_B, 500), "only the replacement bgm is audible")
end

function T.effects_overlap_bgm_and_report_player_completion()
  local sound = newGameSound()
  sound:playMusic("SEQ_TEST_BGM")
  sound:play(1)
  Assert.isTrue(sound:isEffectPlaying(1), "the effect is playing on its player")
  Assert.isFalse(sound:isSaveStable(), "an effect that can be awaited blocks saving")
  local pcm = sound:render(600)
  Assert.deepEqual(left(pcm, 500), mixedAB(500), "the effect overlaps the bgm")
  local tail = {}
  for i = 1, 100 do
    tail[i] = pcm[(500 + i) * 2 - 1]
  end
  Assert.deepEqual(tail, wavePattern(WAVE_A, 100), "the bgm outlives the effect")
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
  Assert.deepEqual(left(sound:render(500), 500), wavePattern(WAVE_B, 500), "the replacement effect plays")
  Assert.isTrue(sound:isEffectPlaying(1), "the replacement effect keeps its player busy through its window")
  Assert.deepEqual(
    left(sound:render(500), 500),
    wavePattern(WAVE_B, 500),
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
  -- The bgm has run 400 frames when this chunk starts; its 500-frame note
  -- retriggers fresh at its tick boundary inside the chunk (the DS sample
  -- restart the player suite pins), so the expected wave restarts there.
  local expected = {}
  for i = 1, 500 do
    local bgmFrame = 400 + i
    if bgmFrame > 500 then
      bgmFrame = bgmFrame - 500
    end
    expected[i] = WAVE_A[(bgmFrame - 1) % 8 + 1]
  end
  Assert.deepEqual(left(sound:render(500), 500), expected, "the bgm survives the effect stop")
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
  Assert.deepEqual(left(sound:render(500), 500), wavePattern(WAVE_C, 500), "the fanfare plays through its own player")
  Assert.isTrue(sound:isFanfarePlaying(), "the post-fanfare wait interval is still fanfare-playing")
  Assert.isFalse(sound:isSaveStable())
  for _ = 1, FANFARE_POST_WAIT_TICKS - 1 do
    sound:updateFixed()
  end
  Assert.isTrue(sound:isFanfarePlaying(), "the interval holds for its full length")
  Assert.deepEqual(left(sound:render(100), 100), zeros(100), "the bgm stays suspended through the interval")
  sound:updateFixed()
  Assert.isFalse(sound:isFanfarePlaying(), "the interval expired")
  Assert.deepEqual(left(sound:render(500), 500), wavePattern(WAVE_A, 500), "the prior bgm resumes")
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
  Assert.deepEqual(left(sound:render(500), 500), zeros(500), "the fade-out stopped the bgm")
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
  Assert.deepEqual(left(sound:render(500), 500), wavePattern(WAVE_A, 500), "the current bgm plays again")
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
