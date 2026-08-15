-- SequencePlayer contract: the g4 sequence-IR interpreter.
-- It owns players, sequences, tracks, program counters, track wait counters,
-- call stacks, loops, tempo, and track parameters, and drives a VoiceMixer
-- with voice commands. The tick clock is the NNS relationship verified from
-- GBATEK (SSEQ section) and the ARM7 player (SND_seq.c): a quarter note is
-- 48 ticks and tempo is BPM (1..240, default 120); ticks come from an exact
-- integer accumulator (tempo*48 per output frame, one tick per
-- sampleRate*60 accumulator units) so waits are integer ticks and timing
-- never drifts -- NOT a 30 Hz field tick and not MIDI PPQN. Tracks are
-- monophonic: a note occupies its track for its whole duration. Loops
-- follow the ARM7 player: loop_end jumps back to its frame's return index
-- (the instruction after the begin) while the count is positive, the body
-- runs `count` times, count 0 loops forever (the real SEQ_GS_P_SAFARI_ROAD),
-- and an unmatched loop_end is a no-op (the SDK's call-depth-0 case).
-- Every retrigger restarts the sample at its start (DS hardware behavior).
-- Commands whose tick boundary falls inside a
-- render apply at that sample index, and rendering is independent of chunk
-- size. play(sequence, bank) starts the sequence on its player (same player
-- id replaces the running sequence; different player ids mix).

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.AudioCache")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")

local T = {}

local SAMPLE_RATE = 48000
local WAVE_A = { 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000 }
local WAVE_B = { 10000, 9000, 8000, 7000 }

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

local function voice(key, opts)
  opts = opts or {}
  return {
    generator = { kind = "sample", sample = key },
    rootKey = opts.rootKey or 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = opts.pan or 0,
  }
end

local function square(opts)
  opts = opts or {}
  return {
    generator = { kind = "square", duty = 0.5 },
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = opts.pan or 0,
  }
end

local function testBank()
  return AudioFixture.bank(12, "BANK_TEST", nil, { AudioFixture.key(1), AudioFixture.key(2) }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
    [2] = {
      kind = "key_split",
      ranges = {
        { lowKey = 0, highKey = 59, voice = voice(AudioFixture.key(1)) },
        { lowKey = 60, highKey = 127, voice = voice(AudioFixture.key(2)) },
      },
    },
    [3] = {
      kind = "drum_set",
      lowKey = 35,
      highKey = 36,
      voices = { voice(AudioFixture.key(1)), square() },
    },
  })
end

local function seq(instructions, opts)
  opts = opts or {}
  return AudioFixture.sequence(opts.id or 0, opts.symbol or "SEQ_TEST", 12, opts.playerId or 1, {
    entry = 1,
    instructions = instructions,
  }, {
    id = opts.playerId or 1,
    initialVolume = opts.initialVolume or 127,
    channelPriority = opts.channelPriority or 64,
    playerPriority = opts.playerPriority or 64,
  })
end

local function buildBundle(sequences, opts)
  opts = opts or {}
  local keyA, keyB = AudioFixture.key(1), AudioFixture.key(2)
  local bundle = AudioFixture.bundle()
  local indexSequences, indexPlayers, bySymbol = {}, {}, {}
  for id, sequence in pairs(sequences) do
    indexSequences[id] = {
      id = id,
      symbol = sequence.symbol,
      file = AudioCache.sequencePath(id),
      bankId = sequence.bankId,
      playerId = sequence.player.id,
    }
    bySymbol[sequence.symbol] = id
    indexPlayers[sequence.player.id] = {
      id = sequence.player.id,
      maxSequences = 16,
      channelMask = 0xFFFF,
      heapSize = 0x2000,
    }
  end
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = { [12] = { id = 12, symbol = "BANK_TEST", file = AudioCache.bankPath(12), waveArchives = {} } }
  bundle.index.bySymbol = bySymbol
  bundle.sequences = sequences
  bundle.banks = { [12] = opts.bank or testBank() }
  bundle.samples = {
    [keyA] = AudioFixture.pcm16le(WAVE_A),
    [keyB] = AudioFixture.pcm16le(WAVE_B),
  }
  bundle.sampleMetadata = {
    [keyA] = AudioFixture.sampleMetadata(
      keyA,
      { frames = 8, sampleRate = SAMPLE_RATE, loop = { startFrame = 0, endFrame = 8 } }
    ),
    [keyB] = AudioFixture.sampleMetadata(
      keyB,
      { frames = 4, sampleRate = SAMPLE_RATE, loop = { startFrame = 0, endFrame = 4 } }
    ),
  }
  return bundle
end

local function engine(sequences, opts)
  opts = opts or {}
  local bundle = buildBundle(sequences, opts)
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(bundle))
  local mixer = opts.mixer or VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = SequencePlayer.new({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  return player, provider
end

local function play(player, provider)
  player:play(provider:sequence(0), provider:bank(12))
end

-- The left channel of the first `frames` frames.
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

local function concat(a, b)
  local out = {}
  for i = 1, #a do
    out[i] = a[i]
  end
  for i = 1, #b do
    out[#out + 1] = b[i]
  end
  return out
end

-- The loop {0, #wave} pattern a wave renders over `frames` frames.
local function wavePattern(wave, frames)
  local out = {}
  for i = 1, frames do
    out[i] = wave[(i - 1) % #wave + 1]
  end
  return out
end

-- wavePattern at a nonzero pitch ratio: the sample advances floor((i-1)*ratio)
-- per frame inside the loop window (ratio 1 is wavePattern). Matches the
-- mixer's nearest-sample read of a voice pitched by (key-rootKey)/12.
local function wavePatternAtRatio(wave, frames, ratio)
  local out = {}
  for i = 1, frames do
    out[i] = wave[math.floor((i - 1) * ratio) % #wave + 1]
  end
  return out
end

function T.plays_a_note_and_ends_the_sequence()
  local player, provider =
    engine({ [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } }) })
  local before = player:render(8)
  for i = 1, 16 do
    Assert.equal(before[i], 0, "nothing plays before play()")
  end
  play(player, provider)
  Assert.isTrue(player:isPlaying())
  local pcm = player:render(600)
  Assert.deepEqual(
    left(pcm, 600),
    concat(wavePattern(WAVE_A, 500), zeros(100)),
    "a 1-tick note at tempo 120 is 500 frames at 48 kHz"
  )
  Assert.isFalse(player:isPlaying(), "the end terminates the sequence")
end

function T.a_note_occupies_the_track_for_its_whole_duration()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 2 },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(1500)
  Assert.deepEqual(
    left(pcm, 1500),
    concat(wavePattern(WAVE_A, 1000), wavePattern(WAVE_B, 500)),
    "tracks are monophonic: the second note starts only when the first one's duration ends"
  )
end

function T.rests_gate_the_next_instruction()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "rest", duration = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(2000)
  Assert.deepEqual(left(pcm, 2000), concat(wavePattern(WAVE_A, 500), concat(zeros(1000), wavePattern(WAVE_A, 500))))
end

function T.tempo_is_bpm_with_48_ticks_per_quarter_note()
  local function noteLength(tempo)
    local player, provider = engine({
      [0] = seq({
        { op = "tempo", amount = tempo },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    })
    play(player, provider)
    local frames = left(player:render(1000), 1000)
    local length = 0
    for frame = 1, 1000 do
      if frames[frame] ~= 0 then
        length = length + 1
      end
    end
    return length
  end
  Assert.equal(noteLength(120), 500, "GBATEK: 48 ticks per quarter note; at 120 BPM one tick is 60/(120*48) s")
  Assert.equal(noteLength(240), 250, "double tempo halves the tick")
end

function T.program_changes_select_other_instruments()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(1000)
  Assert.deepEqual(left(pcm, 1000), concat(wavePattern(WAVE_A, 500), wavePattern(WAVE_B, 500)))
end

function T.jump_loops_back_to_its_target()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(1000)
  Assert.deepEqual(
    left(pcm, 1000),
    concat(wavePattern(WAVE_A, 500), wavePattern(WAVE_A, 500)),
    "the jump restarts the note fresh: DS hardware restarts the sample at the loop start on every retrigger"
  )
  Assert.isTrue(player:isPlaying(), "an open loop keeps playing")
end

-- The SDK's 0xFD with no active call (call depth 0) is a no-op: real tracks
-- end with a top-level return, so a return reached without a call must fall
-- through (and past the program tail the track ends) instead of faulting.
function T.top_level_returns_are_no_ops_and_the_program_tail_ends_the_track()
  local midProgram = {
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "return" },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(midProgram) })
  play(player, provider)
  local pcm = player:render(1000)
  Assert.deepEqual(
    left(pcm, 1000),
    concat(wavePattern(WAVE_A, 500), wavePattern(WAVE_A, 500)),
    "a top-level return falls through to the next instruction like the SDK"
  )

  local trailing = {
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "return" },
  }
  local tailPlayer, tailProvider = engine({ [0] = seq(trailing) })
  play(tailPlayer, tailProvider)
  local tailPcm = tailPlayer:render(1000)
  Assert.deepEqual(
    left(tailPcm, 1000),
    concat(wavePattern(WAVE_A, 500), zeros(500)),
    "a trailing top-level return falls past the program tail and ends the track"
  )
  Assert.isFalse(tailPlayer:isPlaying())
end

function T.call_and_return_execute_a_subprogram()
  local program = {
    { op = "call", target = 4 },
    { op = "rest", duration = 1 },
    { op = "end" },
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "return" },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(1000)
  Assert.deepEqual(
    left(pcm, 1000),
    concat(wavePattern(WAVE_A, 500), zeros(500)),
    "the call returns to the instruction after it"
  )
  Assert.isFalse(player:isPlaying())
end

function T.open_track_plays_a_second_voice_in_parallel()
  local program = {
    { op = "open_track", track = 1, target = 5 },
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(500)
  local expected = {}
  for i = 1, 500 do
    expected[i] = WAVE_A[(i - 1) % 8 + 1] + WAVE_B[(i - 1) % 4 + 1]
  end
  Assert.deepEqual(left(pcm, 500), expected, "both tracks sound from the first frame")
  Assert.isFalse(player:isPlaying(), "the sequence ends when every track ends")
end

function T.pitch_bend_and_transpose_shift_the_pitch_ratio()
  local function renderFor(prefix, frames)
    local player, provider = engine({ [0] = seq(prefix) })
    play(player, provider)
    return left(player:render(frames), frames)
  end
  local bend = renderFor({
    { op = "pitch_bend_range", amount = 48 },
    { op = "pitch_bend", amount = 96 },
    { op = "note", key = 60, velocity = 127, duration = 2 },
    { op = "end" },
  }, 1000)
  Assert.deepEqual(bend, wavePattern({ 1000, 3000, 5000, 7000 }, 1000), "bend 96 at range 48 is +12 semitones: ratio 2")
  local transpose = renderFor({
    { op = "transpose", amount = -12 },
    { op = "note", key = 60, velocity = 127, duration = 2 },
    { op = "end" },
  }, 1000)
  Assert.deepEqual(
    transpose,
    wavePattern(
      { 1000, 1000, 2000, 2000, 3000, 3000, 4000, 4000, 5000, 5000, 6000, 6000, 7000, 7000, 8000, 8000 },
      1000
    ),
    "transpose -12 is an octave down: ratio 0.5"
  )
end

function T.volume_and_expression_scale_the_gain_linearly()
  local function renderFor(prefix)
    local player, provider = engine({ [0] = seq(prefix) })
    play(player, provider)
    return left(player:render(500), 500)
  end
  local expression = renderFor({
    { op = "expression", amount = 64 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(expression[1], math.floor(1000 * 64 / 127 + 0.5), "expression scales linearly, rounded")
  local volume = renderFor({
    { op = "volume", amount = 64 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(volume[1], math.floor(1000 * 64 / 127 + 0.5), "volume scales linearly, rounded")
end

function T.pan_moves_notes_across_the_stereo_field()
  local bank = AudioFixture.bank(12, "BANK_TEST", nil, { AudioFixture.key(1) }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1), { pan = 64 }) },
  })
  local function renderFor(pan)
    local player, provider = engine({
      [0] = seq({
        { op = "pan", amount = pan },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { bank = bank })
    play(player, provider)
    return player:render(500)
  end
  local leftOnly = renderFor(0)
  Assert.deepEqual(left(leftOnly, 500), wavePattern(WAVE_A, 500), "track pan 0 pushes a center voice fully left")
  local rightOnly = renderFor(127)
  for i = 1, 500 do
    Assert.equal(rightOnly[i * 2 - 1], 0, "track pan 127 pushes a center voice fully right")
    Assert.equal(rightOnly[i * 2], WAVE_A[(i - 1) % 8 + 1])
  end
  local center = renderFor(64)
  for i = 1, 500 do
    Assert.equal(center[i * 2 - 1], center[i * 2], "track pan 64 keeps the voice centered")
    Assert.isTrue(center[i * 2 - 1] > 0)
  end
end

function T.random_operands_resolve_deterministically_per_play()
  local program = {
    { op = "pan", amount = { kind = "random", min = 0, max = 127 } },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local a, providerA = engine({ [0] = seq(program) })
  play(a, providerA)
  local first = a:render(500)
  local b, providerB = engine({ [0] = seq(program) })
  play(b, providerB)
  local second = b:render(500)
  Assert.deepEqual(first, second, "the same program with a random operand renders identically")
end

function T.the_player_initial_volume_scales_the_voice()
  local function renderWith(initialVolume)
    local player, provider = engine({
      [0] = seq(
        { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } },
        { initialVolume = initialVolume }
      ),
    })
    play(player, provider)
    return left(player:render(500), 500)
  end
  Assert.equal(renderWith(127)[1], 1000, "initial volume 127 is unity")
  Assert.equal(renderWith(64)[1], math.floor(1000 * 64 / 127 + 0.5), "initial volume folds into the voice gain")
end

function T.playing_on_the_same_player_replaces_the_sequence()
  local first =
    { { op = "program", program = 0 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local second =
    { { op = "program", program = 1 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local player, provider = engine({
    [0] = seq(first),
    [1] = seq(second, { id = 1, symbol = "SEQ_TEST_B", playerId = 1 }),
  })
  play(player, provider)
  local firstRender = player:render(600)
  Assert.deepEqual(left(firstRender, 600), wavePattern(WAVE_A, 600))
  player:play(provider:sequence(1), provider:bank(12))
  local secondRender = player:render(600)
  Assert.deepEqual(
    left(secondRender, 600),
    wavePattern(WAVE_B, 600),
    "the replacement releases the previous note: no wave A sample survives"
  )
end

function T.sequences_on_different_players_mix()
  local programA =
    { { op = "program", program = 0 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local programB =
    { { op = "program", program = 1 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local player, provider = engine({
    [0] = seq(programA, { playerId = 1 }),
    [1] = seq(programB, { id = 1, symbol = "SEQ_TEST_B", playerId = 2 }),
  })
  player:play(provider:sequence(0), provider:bank(12))
  player:play(provider:sequence(1), provider:bank(12))
  local pcm = player:render(1000)
  local expected = {}
  for i = 1, 1000 do
    expected[i] = WAVE_A[(i - 1) % 8 + 1] + WAVE_B[(i - 1) % 4 + 1]
  end
  Assert.deepEqual(left(pcm, 1000), expected, "two players mix like two hardware players")
  Assert.isFalse(player:isPlaying())
end

function T.stop_releases_all_voices()
  local player, provider =
    engine({ [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }) })
  play(player, provider)
  local first = player:render(200)
  Assert.equal(left(first, 200)[1], 1000)
  player:stop()
  Assert.isFalse(player:isPlaying())
  local after = player:render(400)
  for i = 1, 800 do
    Assert.equal(after[i], 0, "stop releases every voice")
  end
end

function T.render_is_deterministic_and_chunk_independent()
  local program = {
    { op = "tempo", amount = 128 },
    { op = "note", key = 60, velocity = 127, duration = 3 },
    { op = "end" },
  }
  local function playChunked(chunks)
    local player, provider = engine({ [0] = seq(program) })
    play(player, provider)
    local out = {}
    for _, frames in ipairs(chunks) do
      local pcm = player:render(frames)
      for i = 1, #pcm do
        out[#out + 1] = pcm[i]
      end
    end
    return out
  end
  local one = playChunked({ 2000 })
  Assert.deepEqual(one, playChunked({ 700, 700, 600 }), "fractional ticks per frame are chunk-size independent")
  Assert.deepEqual(one, playChunked({ 2000 }), "playback is reproducible")
end

function T.playing_a_sequence_with_a_mismatched_bank_fails()
  local player, provider = engine({ [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 1 } }) })
  local bank = provider:bank(12)
  bank.id = 99
  throwsCode("AUDIO_PLAYER_BANK_MISMATCH", function()
    player:play(provider:sequence(0), bank)
  end)
end

function T.playing_an_unknown_instrument_is_silent()
  -- A program the bank does not define is a silent note: the NNS
  -- SND_ReadInstData failure path skips the note, and the real corpus
  -- references placeholder/unused instruments (48 sequences) that the DS
  -- plays as silence, never as a fault.
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 9 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(600)
  Assert.deepEqual(left(pcm, 600), zeros(600), "a missing instrument is a silent note")
  Assert.isFalse(player:isPlaying())
end

function T.unsupported_ops_amounts_and_runaway_loops_fail_loudly()
  throwsCode("AUDIO_PLAYER_UNSUPPORTED_AMOUNT", function()
    local player, provider = engine({
      [0] = seq({
        { op = "volume", amount = { kind = "variable" } },
        { op = "end" },
      }),
    })
    play(player, provider)
    player:render(10)
  end)
  throwsCode("AUDIO_PLAYER_UNSUPPORTED_OP", function()
    local player, provider = engine({ [0] = seq({ { op = "sustain_hold" }, { op = "end" } }) })
    play(player, provider)
    player:render(10)
  end)
  throwsCode("AUDIO_PLAYER_UNBOUNDED_EXECUTION", function()
    local player, provider = engine({ [0] = seq({ { op = "jump", target = 1 } }) })
    play(player, provider)
    player:render(10)
  end)
end

function T.key_split_instruments_select_by_note_key()
  local program = {
    { op = "program", program = 2 },
    { op = "note", key = 30, velocity = 127, duration = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(1000)
  Assert.deepEqual(
    left(pcm, 1000),
    concat(wavePatternAtRatio(WAVE_A, 500, 2 ^ ((30 - 60) / 12)), wavePattern(WAVE_B, 500)),
    "key 30 hits the low range, key 60 the high range; each note renders at its key's pitch ratio"
  )
end

function T.drum_set_voices_select_by_key_and_out_of_range_is_silent()
  local program = {
    { op = "program", program = 3 },
    { op = "note", key = 35, velocity = 127, duration = 1 },
    { op = "note", key = 36, velocity = 127, duration = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(1500)
  local squareFrames = {}
  for i = 1, 500 do
    local phase = math.floor((i - 1) * 0.25) % 8
    squareFrames[i] = phase < 4 and -32767 or 32767
  end
  local expected = concat(wavePatternAtRatio(WAVE_A, 500, 2 ^ ((35 - 60) / 12)), concat(squareFrames, zeros(500)))
  Assert.deepEqual(
    left(pcm, 1500),
    expected,
    "drum 35 plays the sample voice at its key's ratio, drum 36 the square, key 60 is out of range and silent"
  )
end

function T.loop_begin_and_loop_end_repeat_the_body()
  local program = {
    { op = "loop_begin", count = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "loop_end" },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(2000)
  Assert.deepEqual(
    left(pcm, 2000),
    concat(concat(wavePattern(WAVE_A, 500), wavePattern(WAVE_A, 500)), zeros(1000)),
    "count 2 runs the body twice (the SDK decrements at loop_end and exits at zero), then falls through"
  )
  Assert.isFalse(player:isPlaying())
end

-- The SDK's loopCount 0 never decrements: loop_end jumps back forever, so a
-- count-0 loop rings until the sequence is stopped (the real
-- SEQ_GS_P_SAFARI_ROAD map music).
function T.loop_begin_count_zero_loops_forever()
  local player, provider = engine({
    [0] = seq({
      { op = "loop_begin", count = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "loop_end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(2000)
  Assert.deepEqual(
    left(pcm, 2000),
    concat(
      concat(wavePattern(WAVE_A, 500), wavePattern(WAVE_A, 500)),
      concat(wavePattern(WAVE_A, 500), wavePattern(WAVE_A, 500))
    ),
    "count 0 re-enters the body forever"
  )
  Assert.isTrue(player:isPlaying(), "a count-0 loop never ends on its own")
end

-- The SDK's 0xFC with no active loop frame (call depth 0) is a no-op; the
-- real corpus contains tracks whose loop code is dead bytes, so an
-- unmatched loop_end must fall through without faulting.
function T.unmatched_loop_end_is_a_no_op()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "loop_end" },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(1000)
  Assert.deepEqual(left(pcm, 1000), concat(wavePattern(WAVE_A, 500), zeros(500)))
  Assert.isFalse(player:isPlaying())
end

function T.note_commands_carry_the_full_voice_spec()
  local notes, noteOffs = {}, {}
  local stubMixer = {
    noteOn = function(_, spec)
      notes[#notes + 1] = spec
      return 3
    end,
    noteOff = function(_, channel)
      noteOffs[#noteOffs + 1] = channel
    end,
    render = function(_, frames)
      local out = {}
      for i = 1, frames * 2 do
        out[i] = 0
      end
      return out
    end,
  }
  local player, provider = engine({
    [0] = seq(
      { { op = "note", key = 64, velocity = 96, duration = 1 }, { op = "end" } },
      { initialVolume = 100, channelPriority = 32, playerPriority = 16 }
    ),
  }, { mixer = stubMixer })
  player:play(provider:sequence(0), provider:bank(12))
  player:render(500)
  Assert.equal(#notes, 1, "one note, one voice command")
  local spec = notes[1]
  Assert.deepEqual(spec.generator, { kind = "sample", sample = AudioFixture.key(1) })
  Assert.equal(spec.sampleRate, SAMPLE_RATE)
  Assert.equal(spec.pcm, AudioFixture.pcm16le(WAVE_A), "the mixer receives the decoded PCM bytes")
  Assert.deepEqual(spec.loop, { startFrame = 0, endFrame = 8 })
  Assert.equal(spec.loopEnabled, true, "the mixer receives the wave's loop flag")
  Assert.equal(spec.key, 64)
  Assert.equal(spec.rootKey, 60)
  Assert.equal(spec.velocity, 96)
  Assert.equal(spec.volume, 100, "the player volume folds into the voice volume")
  Assert.equal(spec.expression, 127)
  Assert.deepEqual(spec.envelope, { attack = 127, decay = 0, sustain = 127, release = 127 })
  Assert.equal(spec.pan, 0)
  Assert.equal(spec.channelPriority, 32)
  Assert.equal(spec.playerPriority, 16)
  Assert.equal(spec.channelMask, 0xFFFF)
  Assert.deepEqual(noteOffs, { 3 }, "the note releases the channel the mixer assigned")
end

-- The per-player queries GameSound builds its wait and stop semantics on:
-- a player is playing while any of its tracks run, and stopping one player
-- releases exactly that player's voices.
function T.stop_player_releases_only_that_player()
  local bgm = seq({
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  }, { playerId = 1 })
  local effect = seq(
    { { op = "program", program = 1 }, { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } },
    {
      id = 1,
      symbol = "SEQ_EFFECT",
      playerId = 2,
    }
  )
  local player, provider = engine({ [0] = bgm, [1] = effect })
  player:play(provider:sequence(0), provider:bank(12))
  player:play(provider:sequence(1), provider:bank(12))
  player:render(200)
  Assert.isTrue(player:isPlayerPlaying(1))
  Assert.isTrue(player:isPlayerPlaying(2))
  player:stopPlayer(2)
  Assert.isFalse(player:isPlayerPlaying(2), "the stopped player reports free")
  Assert.isTrue(player:isPlayerPlaying(1), "the other player keeps running")
  -- 200 frames rendered before the stop, so this chunk stays inside the
  -- bgm's continuing 500-frame note window: no retrigger phase shift.
  local pcm = player:render(300)
  local expected = {}
  for i = 1, 300 do
    expected[i] = WAVE_A[(200 + i - 1) % 8 + 1]
  end
  Assert.deepEqual(left(pcm, 300), expected, "only the bgm survives the effect stop")
  Assert.isTrue(player:isPlaying())
end

function T.an_ended_or_never_played_player_reports_free()
  local player, provider =
    engine({ [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } }, { playerId = 2 }) })
  Assert.isFalse(player:isPlayerPlaying(2), "a player with no instance reports free")
  player:play(provider:sequence(0), provider:bank(12))
  player:render(600)
  Assert.isFalse(player:isPlayerPlaying(2), "a player whose sequence ended reports free")
  Assert.isFalse(player:isPlaying())
  player:stopPlayer(2)
  player:stopPlayer(9)
end

-- The real HGSS corpus vocabulary: 0x80 `wait` gates the track without
-- releasing a ringing note, 0xFF `end` terminates the track,
-- and 0xC7 `note_wait` clears the note-gating flag (fresh tracks start with
-- it set, per the NNS TrackStart initialization), so composers pair every
-- note with explicit waits. The note's own duration bounds its ring
-- independently of gates (the NNS channel length).
function T.wait_gates_the_track_while_the_note_rings_its_own_length()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "wait", duration = 1 },
      { op = "wait", duration = 1 },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(2000)
  Assert.deepEqual(
    left(pcm, 2000),
    concat(wavePattern(WAVE_A, 1000), zeros(1000)),
    "a note whose gating is cleared rings exactly its own duration; the waits gate without releasing it"
  )
  Assert.isFalse(player:isPlaying(), "end terminates the track")
end

function T.note_wait_clearing_makes_subsequent_notes_ungated()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(1000)
  Assert.deepEqual(
    left(pcm, 1000),
    concat(wavePattern(WAVE_A, 500), zeros(500)),
    "with the note-gating flag cleared the second note replaces the first immediately"
  )
end

-- 0xC6 `priority` overrides the note's channel allocation priority; without
-- the command the player record's channelPriority applies unchanged (the
-- voice-spec contract above).
function T.priority_overrides_the_player_channel_priority_for_its_notes()
  local notes = {}
  local stubMixer = {
    noteOn = function(_, spec)
      notes[#notes + 1] = spec
      return 3
    end,
    noteOff = function() end,
    render = function(_, frames)
      local out = {}
      for i = 1, frames * 2 do
        out[i] = 0
      end
      return out
    end,
  }
  local player, provider = engine({
    [0] = seq(
      { { op = "priority", amount = 12 }, { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } },
      { channelPriority = 32 }
    ),
  }, { mixer = stubMixer })
  player:play(provider:sequence(0), provider:bank(12))
  player:render(500)
  Assert.equal(notes[1].channelPriority, 12, "the priority command overrides the player channel priority")
end

-- The corpus-reachable commands whose effects V1 does not model (LFO
-- modulation parameters, pitch sweep, portamento, per-track envelope
-- overrides, reserved no-ops) are accepted without fault: they carry the
-- frozen vocabulary shapes and must never fail a reachable sequence.
function T.modulation_sweep_portamento_and_envelope_commands_are_accepted()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "nop" },
      { op = "mod_depth", amount = 100 },
      { op = "mod_speed", amount = 10 },
      { op = "mod_range", amount = 3 },
      { op = "mod_delay", amount = 16 },
      { op = "mod_type", amount = 1 },
      { op = "wait", duration = 1 },
      { op = "sweep", amount = -100 },
      { op = "portamento_key", amount = 64 },
      { op = "portamento_time", amount = 8 },
      { op = "release", amount = 90 },
      { op = "wait", duration = 1 },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(1500)
  Assert.deepEqual(
    left(pcm, 1500),
    concat(wavePattern(WAVE_A, 500), zeros(1000)),
    "the unmodeled commands gate nothing and release nothing"
  )
  Assert.isFalse(player:isPlaying())
end

-- 0xB0 `setvar` writes player variables and variable amount operands read
-- them back (the real 0x81-variable program references in the corpus).
function T.setvar_and_variable_amounts_resolve_from_player_variables()
  local player, provider = engine({
    [0] = seq({
      { op = "setvar", var = 0, amount = 1 },
      { op = "program", program = 0, amount = { kind = "variable", var = 0 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(1000)
  Assert.deepEqual(
    left(pcm, 1000),
    concat(wavePattern(WAVE_B, 500), zeros(500)),
    "the variable amount selects the program the variable names"
  )
end

-- 0xBD `cmp_ne` sets the track comparison and a conditional instruction
-- executes only while it holds (the 0xA2 prefix mechanism of the frozen
-- vocabulary; no conditional instruction occurs in the real corpus).
function T.cmp_ne_gates_conditional_instructions()
  local player, provider = engine({
    [0] = seq({
      { op = "setvar", var = 0, amount = 1 },
      { op = "cmp_ne", var = 0, amount = 2 },
      { conditional = true, op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
    [1] = seq({
      { op = "setvar", var = 0, amount = 1 },
      { op = "cmp_ne", var = 0, amount = 1 },
      { conditional = true, op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }, { id = 1, symbol = "SEQ_FALSE" }),
  })
  player:play(provider:sequence(0), provider:bank(12))
  local pcm = player:render(1000)
  Assert.deepEqual(
    left(pcm, 1000),
    concat(wavePattern(WAVE_A, 500), zeros(500)),
    "a true comparison runs the conditional note"
  )
  player:play(provider:sequence(1), provider:bank(12))
  local silent = player:render(1000)
  Assert.deepEqual(left(silent, 1000), zeros(1000), "a false comparison skips the conditional note")
end

return { tests = T }
