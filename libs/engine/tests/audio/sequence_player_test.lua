-- SequencePlayer contract: the g4 sequence-IR interpreter on the NNS timing
-- and state model (SND_seq.c TrackStepTicks/TrackPlayNote/TrackInit). The
-- tick clock is unchanged: a quarter
-- note is 48 ticks, tempo is BPM (1..240, default 120), and ticks come from an
-- exact integer accumulator (tempo*48 per output frame, one tick per
-- sampleRate*60 units) -- the GBATEK/ARM7 SND_TIMER_RATE relationship the
-- mixer's control cadence (one step per outputRate/192 frames) also derives
-- from. A track processes commands while `wait == 0` and not note-finish
-- waiting (WAIT 0 continues in the same pass); a note under note-wait gates
-- the track for its duration, and a zero-length note becomes a note-FINISH
-- wait that holds the track until the note's voice completes its release --
-- never a one-tick wait. Tracks own a polyphonic voice collection of
-- {channel, generation} handles (never a single channel): notes overlap when
-- note-wait is cleared, each voice rings its own channel length, and a stolen
-- handle's note-off is harmless. State: wait ticks, note-finish wait,
-- note-wait (default true), tie, mute, program, priority (default 64),
-- volume, expression, pan offset (the raw trackPanOffset, default 0),
-- transpose, bend, bend range, nullable envelope overrides (applied to a
-- note only when set), the comparison flag, call/loop stacks, and variables.
-- The player drives the mixer's new-model spec only: trackVolume +
-- playerVolume (never folded), trackPriority + playerPriority, the raw
-- trackPanOffset, the instrument pan, bend folded into `key` (the mixer has
-- no bend field), and {channel, generation} handles with per-Main
-- updateVoice pushes of the current track values. Players process ascending
-- player number and tracks ascending track number over the fixed NNS domains
-- (16 players x 16 tracks), so contested allocation is deterministic. Random
-- operands draw from an injected per-instance RNG (production must not
-- reseed per play); variables live in the 16-local/16-global SDK domain.
-- Rendering is per-frame with instance-carried state, so chunk sizes never
-- change the result.

-- Every exact PCM vector below is derived from the landed VoiceMixer driven
-- with the mandated player spec (the mixer suite pins the underlying NNS
-- math): a note rings at full gain through its duration ticks plus the
-- 250-frame release lag (the control period at 48 kHz), then 250 frames at
-- the release register 0x306 gain (mantissa 6 over the divider shift 4 =
-- 6/2048), then silence -- the noteOff itself never kills the voice.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioCache = require("libs.assets.src.AudioCache")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")
local bit = require("bit")

local T = {}

local SAMPLE_RATE = 48000
local WAVE_A = { 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000 }
local WAVE_B = { 10000, 9000, 8000, 7000 }
local WAVE_C = { 500, 1000, 1500, 2000, 2500, 3000 }

-- The expected-PCM model (release cadence) is shared with the game-sound
-- suite; see tests/support/AudioPattern.lua.
local AudioPattern = require("tests.support.AudioPattern")
local waveAt = AudioPattern.waveAt
local segment = AudioPattern.segment
local noteSegment = AudioPattern.noteSegment
local sumSegments = AudioPattern.sumSegments
local sumSegmentsSaturating = AudioPattern.sumSegmentsSaturating
local slice = AudioPattern.slice

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

local function voice(key, opts)
  opts = opts or {}
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = opts.pan or 0,
  }
end

local function square(opts)
  opts = opts or {}
  return {
    generator = { kind = "square", duty = 0.5 },
    originalKey = 60,
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
  local keyA, keyB, keyC = AudioFixture.key(1), AudioFixture.key(2), AudioFixture.key(3)
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
      channelMask = opts.channelMask or 0xFFFF,
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
    [keyC] = AudioFixture.pcm16le(WAVE_C),
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
    [keyC] = AudioFixture.sampleMetadata(
      keyC,
      { frames = 6, sampleRate = SAMPLE_RATE, loop = { startFrame = 0, endFrame = 6 } }
    ),
  }
  return bundle
end

local function engine(sequences, opts)
  opts = opts or {}
  local bundle = buildBundle(sequences, opts)
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(bundle))
  local mixer = opts.mixer or VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local playerOpts = { sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider }
  if opts.rng ~= nil then
    playerOpts.rng = opts.rng
  end
  local player = SequencePlayer.new(playerOpts)
  return player, provider
end

local function play(player, provider)
  player:play(provider:sequence(0), provider:bank(12))
end

-- A deterministic [0,1) source for the injected-RNG tests.
local function seededRng(seed)
  local state = seed
  return function()
    state = (state * 1103515245 + 12345) % 4294967296
    return state / 4294967296
  end
end

-- A recording mixer implementing the new-model contract: noteOn returns a
-- {channel, generation} handle, noteOff/updateVoice take handles, and every
-- call is logged for assertions.
local function stubMixer()
  local log = { noteOns = {}, noteOffs = {}, updates = {} }
  local mixer = {
    log = log,
    noteOn = function(_, spec)
      log.noteOns[#log.noteOns + 1] = spec
      return { channel = 3, generation = 0 }
    end,
    noteOff = function(_, handle)
      log.noteOffs[#log.noteOffs + 1] = handle
    end,
    updateVoice = function(_, handle, partial)
      log.updates[#log.updates + 1] = { handle = handle, partial = partial }
    end,
    render = function(_, frames)
      local out = {}
      for i = 1, frames * 2 do
        out[i] = 0
      end
      return out
    end,
  }
  return mixer
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

local function samePcm(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- The square voice's full-gain sample at `frame` (duty 0.5, key ratio).
local function squareAt(ratio, startFrame)
  return function(frame)
    local phase = math.floor((frame - startFrame) * ratio) % 8
    return phase < 4 and -32767 or 32767
  end
end

-- The exact NNS pitch ratios the mixer derives from SND_CalcTimer
-- (VoiceMixer voiceRatio): a sample voice reads at sampleRate*baseTimer/
-- (calcTimer(baseTimer, (key-originalKey)*64)*sampleRate), a square at
-- DS_SAMPLE_CLOCK/((calcTimer(8006, (key-60)*64) & 0xFFFC)*sampleRate).
local DS_SAMPLE_CLOCK = 16756991
local function sampleRatio(key, originalKey)
  local timer = NnsSoundMath.calcTimer(8006, (key - originalKey) * 64)
  return SAMPLE_RATE * 8006 / (timer * SAMPLE_RATE)
end
local function squareRatio(key)
  local timer = bit.band(NnsSoundMath.calcTimer(8006, (key - 60) * 64), 0xFFFC)
  return DS_SAMPLE_CLOCK / (timer * SAMPLE_RATE)
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
  local pcm = player:render(1100)
  Assert.deepEqual(
    left(pcm, 1100),
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 1100) }, 1100),
    "a 1-tick note at tempo 120 rings 750 frames at full gain, then the 250-frame release tail"
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
  local pcm = player:render(2000)
  Assert.deepEqual(
    left(pcm, 2000),
    sumSegments({ noteSegment(WAVE_A, 1, 2, 1, 2000), noteSegment(WAVE_B, 1, 1, 1001, 2000) }, 2000),
    "the note's gate holds the track for its whole duration; the second note starts only when the first's gate opens"
  )
end

function T.waits_gate_the_next_instruction()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "wait", duration = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) })
  play(player, provider)
  local pcm = player:render(2000)
  Assert.deepEqual(
    left(pcm, 2000),
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 2000), noteSegment(WAVE_A, 1, 1, 1501, 2000) }, 2000)
  )
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
    local frames = left(player:render(3000), 3000)
    local length = 0
    for frame = 1, 3000 do
      if frames[frame] ~= 0 then
        length = length + 1
      end
    end
    return length
  end
  Assert.equal(
    noteLength(120),
    1000,
    "GBATEK: 48 ticks per quarter note; at 120 BPM one tick is 500 frames, plus the release lag and tail"
  )
  Assert.equal(noteLength(240), 750, "double tempo halves the tick; the release lag and tail stay frame-based")
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
  Assert.deepEqual(
    left(pcm, 1000),
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 1000), noteSegment(WAVE_B, 1, 1, 501, 1000) }, 1000)
  )
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
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 1000), noteSegment(WAVE_A, 1, 1, 501, 1000) }, 1000),
    "the jump retriggers the note at every tick; the ringing note overlaps its retrigger"
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
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 1000), noteSegment(WAVE_A, 1, 1, 501, 1000) }, 1000),
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
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 1000) }, 1000),
    "a trailing top-level return falls past the program tail and ends the track"
  )
  Assert.isFalse(tailPlayer:isPlaying())
end

function T.call_and_return_execute_a_subprogram()
  local program = {
    { op = "call", target = 4 },
    { op = "wait", duration = 1 },
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
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 1000) }, 1000),
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
  local function patternAt(ratio, frames)
    local out = {}
    for i = 1, frames do
      out[i] = WAVE_A[math.floor((i - 1) * ratio) % 8 + 1]
    end
    return out
  end
  local bend = renderFor({
    { op = "pitch_bend_range", amount = 48 },
    { op = "pitch_bend", amount = 96 },
    { op = "note", key = 60, velocity = 127, duration = 2 },
    { op = "end" },
  }, 1000)
  Assert.deepEqual(bend, patternAt(2, 1000), "bend 96 at range 48 is +12 semitones: ratio 2")
  local transpose = renderFor({
    { op = "transpose", amount = -12 },
    { op = "note", key = 60, velocity = 127, duration = 2 },
    { op = "end" },
  }, 1000)
  Assert.deepEqual(transpose, patternAt(0.5, 1000), "transpose -12 is an octave down: ratio 0.5")
end

-- The NNS volume path: velocity, track volume, expression and player volume
-- all enter the channel dB sum through SNDi_DecibelSquareTable
-- (SND_seq.c TrackUpdateChannel), converted by SND_CalcChannelVolume into the
-- register the mixer suite pins (expression/volume 64 -> register 0x141,
-- 100 -> register 0x4F). The player never folds these together.
function T.volume_and_expression_use_the_nns_decibel_domain()
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
  Assert.equal(expression[1], 254, "expression 64 is register 0x141 (65/256), not a linear fold")
  local volume = renderFor({
    { op = "volume", amount = 64 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(volume[1], 254, "volume 64 is the same decibel point as expression 64")
  local louder = renderFor({
    { op = "expression", amount = 100 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(louder[1], 617, "expression 100 is register 0x4F (79/128)")
  local silent = renderFor({
    { op = "expression", amount = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(silent[1], 0, "expression 0 is silence")
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
  local expectedLeft = {}
  for i = 1, 500 do
    expectedLeft[i] = WAVE_A[(i - 1) % 8 + 1]
  end
  Assert.deepEqual(left(leftOnly, 500), expectedLeft, "track pan 0 pushes a center voice fully left")
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

-- Random operands draw from the injected per-instance RNG: the same seed
-- reproduces a play, different seeds diverge (production must not reseed
-- every sequence to a constant -- that is what makes random SSEQs repeat).
function T.random_operands_draw_from_the_injected_rng()
  local program = {
    { op = "pan", amount = { kind = "random", min = 0, max = 127 } },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local a, providerA = engine({ [0] = seq(program) }, { rng = seededRng(1) })
  play(a, providerA)
  local seedA = a:render(500)
  local b, providerB = engine({ [0] = seq(program) }, { rng = seededRng(1) })
  play(b, providerB)
  local seedA2 = b:render(500)
  Assert.isTrue(samePcm(seedA, seedA2), "the same injected seed reproduces the play")
  local c, providerC = engine({ [0] = seq(program) }, { rng = seededRng(2) })
  play(c, providerC)
  local seedB = c:render(500)
  Assert.isFalse(samePcm(seedA, seedB), "a different seed resolves the random operand differently")
end

function T.the_player_initial_volume_passes_through_as_player_volume()
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
  Assert.equal(renderWith(127)[1], 1000, "player volume 127 is unity")
  Assert.equal(
    renderWith(64)[1],
    254,
    "the player volume is passed separately (register 0x141), never folded into the track volume"
  )
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
  local expectedA = {}
  for i = 1, 600 do
    expectedA[i] = WAVE_A[(i - 1) % 8 + 1]
  end
  Assert.deepEqual(left(firstRender, 600), expectedA)
  player:play(provider:sequence(1), provider:bank(12))
  local secondRender = player:render(600)
  local expected = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 2, 1, 1200, 600),
    segment(waveAt(WAVE_B, 1, 601), 2, 601, 1200),
  }, 1200)
  Assert.deepEqual(
    left(secondRender, 600),
    slice(expected, 601, 1200),
    "the replacement releases the previous note: it rings out (full gain to the next control step, then the tail) while the new sequence's note plays"
  )
  local tailExpected = {}
  for i = 401, 600 do
    tailExpected[i - 400] = WAVE_B[(600 + i - 1) % 4 + 1]
  end
  Assert.deepEqual(
    slice(left(secondRender, 600), 401, 600),
    tailExpected,
    "after the old voice's ring-out no wave A sample survives"
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
  local expected = sumSegments({ segment(waveAt(WAVE_A, 1, 1), 1, 1, 600, 200) }, 600)
  local sliced = {}
  for i = 201, 600 do
    sliced[#sliced + 1] = expected[i]
  end
  Assert.deepEqual(
    left(after, 400),
    sliced,
    "stop releases the voice; it rings at full gain to the next control step, then the release tail"
  )
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

-- Malformed programs fail loudly at the authoritative asset boundary: an
-- unknown op or an illegally shaped amount operand is rejected by the closed
-- sequence validator when the provider loads the asset, never accepted into
-- the player. A structurally valid runaway loop still fails the player's
-- host safety budget.
function T.unsupported_ops_amounts_and_runaway_loops_fail_loudly()
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
    local player, provider = engine({
      [0] = seq({
        { op = "volume", amount = { kind = "variable" } },
        { op = "end" },
      }),
    })
    play(player, provider)
    player:render(10)
  end)
  throwsCode("AUDIO_SEQUENCE_INVALID", function()
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
    sumSegments({
      noteSegment(WAVE_A, sampleRatio(30, 60), 1, 1, 1000),
      noteSegment(WAVE_B, sampleRatio(60, 60), 1, 501, 1000),
    }, 1000),
    "key 30 hits the low range, key 60 the high range; each note renders at the exact NNS-calculated ratio"
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
  Assert.deepEqual(
    left(pcm, 1500),
    sumSegmentsSaturating({
      noteSegment(WAVE_A, sampleRatio(35, 60), 1, 1, 1500),
      segment(squareAt(squareRatio(36), 501), 1, 501, 1500),
    }, 1500),
    "drum 35 plays the sample voice at its exact NNS ratio, drum 36 the square, key 60 is out of range and silent"
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
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 2000), noteSegment(WAVE_A, 1, 1, 501, 2000) }, 2000),
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
    sumSegments({
      noteSegment(WAVE_A, 1, 1, 1, 2000),
      noteSegment(WAVE_A, 1, 1, 501, 2000),
      noteSegment(WAVE_A, 1, 1, 1001, 2000),
      noteSegment(WAVE_A, 1, 1, 1501, 2000),
    }, 2000),
    "count 0 re-enters the body forever, retriggering over the ringing note"
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
  Assert.deepEqual(left(pcm, 1000), sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 1000) }, 1000))
  Assert.isFalse(player:isPlaying())
end

-- WAIT 0 must not delay execution to the next tick: the SDK command loop
-- continues while `wait == 0 && !note_finish_wait`, so the next command runs
-- in the same processing pass.
function T.wait_zero_runs_the_next_command_in_the_same_pass()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(2000)
  Assert.deepEqual(
    left(pcm, 2000),
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 2000), noteSegment(WAVE_A, 1, 1, 501, 2000) }, 2000),
    "the second note starts in the same pass as the WAIT 0 executes, at the first tick"
  )
end

-- A zero-length note under note-wait is a note-FINISH wait (SND_seq.c
-- TrackPlayNote: wait = length; if length == 0 -> note_finish_wait): the
-- track holds until the note's voice completes its release -- with a long
-- release that is many ticks, materially different from a one-tick wait. The
-- release override (release 126 -> 7 control steps) makes the finish
-- observable: the marker note must not start at the one-tick boundary.
function T.zero_length_notes_wait_for_the_note_to_finish()
  local player, provider = engine({
    [0] = seq({
      { op = "release", amount = 126 },
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 0 },
      { op = "program", program = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = left(player:render(6000), 6000)
  local onset = nil
  for frame = 501, 6000 do
    if pcm[frame] >= 9000 then
      onset = frame
      break
    end
  end
  Assert.notNil(onset, "the marker note eventually plays: the finish wait does not hang the track")
  Assert.isTrue(
    onset >= 1500,
    "the marker note starts only after the zero-length note's release completes (release 126 spans ~7 control steps)"
  )
  Assert.isTrue(onset <= 6000, "the marker note starts inside the render window")
  Assert.isTrue(pcm[onset] >= 10000 and pcm[onset] <= 10008, "the marker note begins its own wave at full gain")
  Assert.isFalse(player:isPlaying(), "the sequence completes once the marker note rings out")
end

-- The NNS track polyphony: with note-wait cleared, overlapping notes all
-- sound; each voice rings its own channel length independently. The track's
-- voice collection is a list of {channel, generation} handles -- never a
-- single channel.
function T.overlapping_notes_form_a_polyphonic_voice_collection()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(2000)
  Assert.deepEqual(
    left(pcm, 2000),
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 2000), noteSegment(WAVE_A, 1, 2, 1, 2000) }, 2000),
    "the second note overlaps the first instead of replacing it; both ring their own lengths"
  )
end

-- The per-voice length bookkeeping: each {channel, generation} handle in the
-- track's collection expires on its own tick, and the handle the mixer
-- returned is what comes back on noteOff.
function T.the_track_keeps_polyphonic_voice_handles_and_releases_them_individually()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "note", key = 61, velocity = 127, duration = 2 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "both notes allocated in the first pass")
  Assert.equal(#mixer.log.noteOffs, 0, "no voice is replaced while the collection is polyphonic")
  player:render(500)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { channel = 3, generation = 0 } },
    "the first voice's length expires at its own tick"
  )
  player:render(500)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { channel = 3, generation = 0 }, { channel = 3, generation = 0 } },
    "the second voice's length expires on its own later tick"
  )
end

-- The NNS tie: the tie command itself releases the track's active voices
-- (SND_seq.c 0xC8 TrackReleaseChannels + TrackFreeChannels); a tied note
-- reuses the active voice instead of allocating (its key/velocity change
-- in place, the envelope never restarts), so no noteOn and no noteOff fires
-- for it; an untied note allocates normally.
function T.tie_releases_existing_voices_and_tied_notes_do_not_reallocate()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "tie", amount = 1 },
      { op = "note", key = 61, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "note", key = 62, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "tie", amount = 0 },
      { op = "wait", duration = 1 },
      { op = "note", key = 63, velocity = 127, duration = 2 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1, "the first note allocates")
  player:render(600)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { channel = 3, generation = 0 } },
    "the tie command releases the track's existing voice"
  )
  Assert.equal(#mixer.log.noteOns, 2, "the tied note after the release allocates normally")
  player:render(600)
  Assert.equal(#mixer.log.noteOns, 2, "a tied note over an active voice allocates nothing")
  Assert.equal(#mixer.log.noteOffs, 1, "a tied note does not release the reused voice either")
  player:render(600)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { channel = 3, generation = 0 }, { channel = 3, generation = 0 } },
    "clearing tie releases the reused voice before the next allocation"
  )
  player:render(600)
  Assert.equal(#mixer.log.noteOns, 3, "the untied note after tie-off allocates normally")
end

-- Mute modes (SND_seq.c TrackMute): mode 1 mutes future notes without
-- touching playing voices, mode 2 additionally releases the track's voices,
-- mode 0 unmutes. A muted note still gates the track like any other note.
function T.mute_modes_suppress_notes_and_clean_up_voices()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 3 },
      { op = "wait", duration = 1 },
      { op = "mute", amount = 1 },
      { op = "note", key = 61, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "mute", amount = 2 },
      { op = "wait", duration = 1 },
      { op = "mute", amount = 0 },
      { op = "note", key = 62, velocity = 127, duration = 2 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1, "the first note allocates")
  player:render(600)
  Assert.equal(#mixer.log.noteOns, 1, "a muted note allocates no voice")
  Assert.equal(#mixer.log.noteOffs, 0, "mute mode 1 leaves playing voices alone")
  player:render(600)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { channel = 3, generation = 0 } },
    "mute mode 2 releases the track's playing voices"
  )
  player:render(600)
  Assert.equal(#mixer.log.noteOns, 2, "unmuting restores note playback")
end

-- Envelope overrides (SND_seq.c 0xD0-0xD3) start unset (0xFF in the SDK) and
-- only apply to a note when set: an unset override leaves the instrument's
-- envelope untouched; a set override replaces exactly that stage and
-- persists for every later note.
function T.envelope_overrides_apply_only_when_set_and_persist()
  local mixer = stubMixer()
  local program = {
    { op = "note_wait", amount = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "attack", amount = 100 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "decay", amount = 80 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "sustain", amount = 60 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "release", amount = 90 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  local base = { attack = 127, decay = 0, sustain = 127, release = 127 }
  Assert.deepEqual(mixer.log.noteOns[1].envelope, base, "an unset override leaves the voice envelope untouched")
  Assert.deepEqual(
    mixer.log.noteOns[2].envelope,
    { attack = 100, decay = 0, sustain = 127, release = 127 },
    "a set attack override replaces exactly the attack stage"
  )
  Assert.deepEqual(
    mixer.log.noteOns[3].envelope,
    { attack = 100, decay = 80, sustain = 127, release = 127 },
    "the decay override joins the persisted attack override"
  )
  Assert.deepEqual(
    mixer.log.noteOns[4].envelope,
    { attack = 100, decay = 80, sustain = 60, release = 127 },
    "the sustain override joins the persisted overrides"
  )
  Assert.deepEqual(
    mixer.log.noteOns[5].envelope,
    { attack = 100, decay = 80, sustain = 60, release = 90 },
    "the release override joins the persisted overrides"
  )
end

-- Every comparison command drives the track comparison flag; a conditional
-- instruction runs only while it holds (the 0xA2 prefix mechanism of the
-- frozen vocabulary). Table-driven over the six operators.
function T.every_comparison_operator_drives_conditional_execution()
  local cases = {
    { op = "cmp_eq", trueAmount = 5, falseAmount = 4 },
    { op = "cmp_ne", trueAmount = 4, falseAmount = 5 },
    { op = "cmp_gt", trueAmount = 4, falseAmount = 5 },
    { op = "cmp_ge", trueAmount = 5, falseAmount = 6 },
    { op = "cmp_lt", trueAmount = 6, falseAmount = 5 },
    { op = "cmp_le", trueAmount = 5, falseAmount = 4 },
  }
  for _, case in ipairs(cases) do
    local function run(amount)
      local mixer = stubMixer()
      local player, provider = engine({
        [0] = seq({
          { op = "setvar", var = 0, amount = 5 },
          { [case.op] = true, op = case.op, var = 0, amount = amount },
          { conditional = true, op = "note", key = 60, velocity = 127, duration = 1 },
          { op = "end" },
        }),
      }, { mixer = mixer })
      play(player, provider)
      player:render(100)
      return #mixer.log.noteOns
    end
    Assert.equal(run(case.trueAmount), 1, case.op .. " true: the conditional note runs")
    Assert.equal(run(case.falseAmount), 0, case.op .. " false: the conditional note is skipped")
  end
end

-- The voice spec is the migrated mixer contract: trackVolume + playerVolume
-- (never folded), trackPriority + playerPriority, the raw trackPanOffset,
-- the instrument pan, bend folded into `key` (the mixer has no bend field),
-- and a {channel, generation} handle back. The old folded fields must not
-- survive.
function T.note_spec_carries_the_migrated_mixer_fields()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq(
      { { op = "note", key = 64, velocity = 96, duration = 1 }, { op = "end" } },
      { initialVolume = 100, channelPriority = 32, playerPriority = 16 }
    ),
  }, { mixer = mixer })
  play(player, provider)
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 1, "one note, one voice command")
  local spec = mixer.log.noteOns[1]
  Assert.deepEqual(spec.generator, { kind = "sample", sample = AudioFixture.key(1) })
  Assert.equal(spec.sampleRate, SAMPLE_RATE)
  Assert.equal(spec.pcm, AudioFixture.pcm16le(WAVE_A), "the mixer receives the decoded PCM bytes")
  Assert.deepEqual(spec.loop, { startFrame = 0, endFrame = 8 })
  Assert.equal(spec.loopEnabled, true, "the mixer receives the wave's loop flag")
  Assert.equal(spec.key, 64)
  Assert.equal(spec.originalKey, 60)
  Assert.equal(spec.velocity, 96)
  Assert.equal(spec.trackVolume, 127, "the track volume passes through unfettered")
  Assert.equal(spec.expression, 127)
  Assert.equal(spec.playerVolume, 100, "the player volume passes separately, never folded into the track volume")
  Assert.deepEqual(spec.envelope, { attack = 127, decay = 0, sustain = 127, release = 127 })
  Assert.equal(spec.pan, 0, "the spec carries the instrument pan, not a folded track pan")
  Assert.equal(spec.trackPanOffset, 0, "the raw track pan offset defaults to 0")
  Assert.equal(spec.channelMask, 0xFFFF)
  Assert.equal(spec.trackPriority, 64, "the track priority defaults to 64")
  Assert.equal(spec.playerPriority, 16)
  Assert.isNil(spec.volume, "the old folded volume field is gone")
  Assert.isNil(spec.channelPriority, "the old channelPriority field is gone")
  Assert.isNil(spec.bend, "bend folds into key; the mixer has no bend field")
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { channel = 3, generation = 0 } },
    "the note releases the {channel, generation} handle the mixer returned"
  )
end

-- The 0xC6 priority command changes the TRACK priority (SDK TrackInit
-- default 64); the note priority is playerPriority + trackPriority, so the
-- priority command never reaches the player record's fields.
function T.priority_is_track_state_defaulting_to_64()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "priority", amount = 12 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }, { channelPriority = 32, playerPriority = 16 }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(mixer.log.noteOns[1].trackPriority, 64, "a fresh track's priority defaults to 64")
  Assert.equal(mixer.log.noteOns[1].playerPriority, 16, "the player priority is untouched by the command")
  Assert.equal(mixer.log.noteOns[2].trackPriority, 12, "the priority command changes the track priority")
end

-- The pan command writes the raw SDK track pan offset (SND_seq.c 0xC0 stores
-- par - 0x40); the instrument pan is untouched.
function T.pan_commands_pass_the_raw_track_pan_offset()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "pan", amount = 64 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "pan", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "pan", amount = 127 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(mixer.log.noteOns[1].trackPanOffset, 0, "the raw offset defaults to 0")
  Assert.equal(mixer.log.noteOns[2].trackPanOffset, 0, "pan 64 is the zero offset")
  Assert.equal(mixer.log.noteOns[3].trackPanOffset, -64, "pan 0 is the full-left offset")
  Assert.equal(mixer.log.noteOns[4].trackPanOffset, 63, "pan 127 is the full-right offset")
  for i = 1, 4 do
    Assert.equal(mixer.log.noteOns[i].pan, 0, "the instrument pan is never folded into the track offset")
  end
end

-- Pitch bend folds into the note key (bend - 64) * bendRange / 128 semitones;
-- the mixer contract has no bend field. Transpose adds raw semitones.
function T.bend_folds_into_key_and_transpose_adds_semitones()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "transpose", amount = -12 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "pitch_bend_range", amount = 48 },
      { op = "pitch_bend", amount = 96 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(mixer.log.noteOns[1].key, 60, "no bend, no transpose: the key is the note key")
  Assert.equal(mixer.log.noteOns[2].key, 48, "transpose -12 shifts the key an octave down")
  Assert.equal(mixer.log.noteOns[3].key, 60, "bend 96 at range 48 is +12 semitones over the transposed key")
  Assert.isNil(mixer.log.noteOns[3].bend, "the mixer spec carries no bend field")
  Assert.equal(mixer.log.noteOns[3].trackVolume, 127, "the folded-key spec still carries the migrated fields")
end

-- Per-Main updateVoice pushes: at the player's main cadence the current
-- track values are pushed to every active voice's {channel, generation}
-- handle, so volume/expression/pan commands become audible at the next
-- mixer control step instead of only at the next note.
function T.track_value_changes_push_update_voice_per_main()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "volume", amount = 60 },
      { op = "pan", amount = 40 },
      { op = "expression", amount = 80 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(600)
  Assert.isTrue(#mixer.log.updates > 0, "the player pushes updateVoice at its main cadence")
  local pushes = {}
  for _, update in ipairs(mixer.log.updates) do
    if
      update.partial.trackVolume == 60
      and update.partial.expression == 80
      and update.partial.trackPanOffset == -24
    then
      pushes[#pushes + 1] = update
    end
  end
  Assert.isTrue(#pushes > 0, "the push carries the current track volume, expression and raw pan offset")
  Assert.deepEqual(pushes[1].handle, { channel = 3, generation = 0 }, "the push targets the active voice's handle")
  Assert.equal(pushes[1].partial.playerVolume, 127, "the push carries the player volume too")
end

-- Deterministic scheduling: the player processes players ascending and each
-- player's tracks ascending over the fixed NNS domains (16 players x 16
-- tracks per player). A contested allocation (one free channel) therefore
-- always goes to the highest-numbered track of a player.
function T.contested_allocation_follows_ascending_track_order()
  local bank = AudioFixture.bank(12, "BANK_TEST", nil, {
    AudioFixture.key(1),
    AudioFixture.key(2),
    AudioFixture.key(3),
  }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
    [2] = { kind = "direct", voice = voice(AudioFixture.key(3)) },
  })
  local program = {
    { op = "open_track", track = 9, target = 7 },
    { op = "open_track", track = 15, target = 11 },
    { op = "wait", duration = 1 },
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 4 },
    { op = "wait", duration = 1 },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 8 },
    { op = "wait", duration = 1 },
    { op = "program", program = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 12 },
  }
  local player, provider = engine({ [0] = seq(program, { symbol = "SEQ_CONTEST" }) }, {
    bank = bank,
    channelMask = 0x0010,
  })
  play(player, provider)
  local pcm = left(player:render(1000), 1000)
  for frame = 501, 1000 do
    Assert.equal(
      pcm[frame],
      WAVE_C[(frame - 501) % 6 + 1],
      "the highest-numbered contested track (15) wins the single allocatable channel"
    )
  end
end

-- Deterministic scheduling across players: different play orders must not
-- change who wins a contested allocation. The NNS player domain is fixed, so
-- iteration is ascending player number, never Lua table order. The settle is
-- observable from the first tick (frame 500): play() runs each entry program
-- immediately in call order, so the pre-tick window holds whichever voice was
-- played last, but at the first tick every track retriggers and the ascending
-- player order hands the single channel to the highest-numbered player (15).
function T.contested_allocation_is_identical_across_player_play_orders()
  local bank = AudioFixture.bank(12, "BANK_TEST", nil, {
    AudioFixture.key(1),
    AudioFixture.key(2),
  }, {
    [0] = { kind = "direct", voice = voice(AudioFixture.key(1)) },
    [1] = { kind = "direct", voice = voice(AudioFixture.key(2)) },
  })
  local function programFor(i, playerId)
    return seq({
      { op = "program", program = i % 2 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "jump", target = 2 },
    }, { id = i, symbol = "SEQ_P" .. playerId, playerId = playerId })
  end
  local function run(order)
    local sequences = {
      [0] = programFor(0, 1),
      [1] = programFor(1, 7),
      [2] = programFor(2, 13),
      [3] = programFor(3, 15),
    }
    local provider = AudioAssetProvider.new(AudioFixture.readyCache(buildBundle(sequences, {
      bank = bank,
      channelMask = 0x0010,
    })))
    local player = SequencePlayer.new({
      sampleRate = SAMPLE_RATE,
      mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE }),
      provider = provider,
    })
    for _, index in ipairs(order) do
      player:play(provider:sequence(index), provider:bank(12))
    end
    return player:render(1000)
  end
  local forward = run({ 0, 1, 2, 3 })
  local backward = run({ 3, 2, 1, 0 })
  Assert.isTrue(
    samePcm(slice(left(forward, 1000), 501, 1000), slice(left(backward, 1000), 501, 1000)),
    "play order never changes the contested allocation winner from the first tick on"
  )
  local settled = {}
  for i = 501, 1000 do
    settled[i] = WAVE_B[(i - 501) % 4 + 1]
  end
  Assert.deepEqual(
    slice(left(forward, 1000), 501, 1000),
    slice(settled, 501, 1000),
    "the ascending player order hands the single channel to player 15"
  )
  Assert.isTrue(samePcm(forward, run({ 0, 1, 2, 3 })), "repeated runs render identically")
end

-- The full NNS track domain: all 16 tracks of a player run, and every note
-- carries the migrated spec.
function T.all_sixteen_tracks_play_in_parallel()
  local mixer = stubMixer()
  local main = {}
  for track = 1, 15 do
    main[#main + 1] = { op = "open_track", track = track, target = 18 + (track - 1) * 2 }
  end
  main[#main + 1] = { op = "note", key = 60, velocity = 127, duration = 1 }
  main[#main + 1] = { op = "end" }
  local instructions = main
  for track = 1, 15 do
    instructions[#instructions + 1] = { op = "note", key = 60, velocity = 127, duration = 1 }
    instructions[#instructions + 1] = { op = "end" }
  end
  local player, provider = engine({ [0] = seq(instructions) }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(#mixer.log.noteOns, 16, "all sixteen tracks note in the first pass")
  for i = 1, 16 do
    Assert.equal(mixer.log.noteOns[i].trackPriority, 64, "track " .. (i - 1) .. " carries the default track priority")
  end
end

-- The per-player queries GameSound builds its wait and stop semantics on:
-- a player is playing while any of its tracks run, and stopping one player
-- releases exactly that player's voices (its released voice rings its tail).
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
  local pcm = player:render(300)
  local expected = sumSegments({
    segment(waveAt(WAVE_A, 1, 1), 1, 1, 500, 500),
    segment(waveAt(WAVE_B, 1, 1), 1, 1, 500, 200),
  }, 500)
  Assert.deepEqual(
    left(pcm, 300),
    slice(expected, 201, 500),
    "only the stopped player's voice rings its release tail; the bgm is untouched"
  )
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
-- it set, per the NNS TrackInit), so composers pair every note with explicit
-- waits. The note's own length bounds its ring independently of gates (the
-- NNS channel length).
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
    sumSegments({ noteSegment(WAVE_A, 1, 2, 1, 2000) }, 2000),
    "a note whose gating is cleared rings exactly its own duration; the waits gate without releasing it"
  )
  Assert.isFalse(player:isPlaying(), "end terminates the track")
end

-- The corpus-reachable track-state commands the player does not model (LFO
-- modulation parameters, pitch sweep, portamento) plus the envelope override
-- commands are accepted without fault: they carry the frozen vocabulary
-- shapes and must never fail a reachable sequence.
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
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 1500) }, 1500),
    "the track-state commands gate nothing and release nothing"
  )
  Assert.isFalse(player:isPlaying())
end

-- 0xB0 `setvar` writes player variables and variable amount operands read
-- them back (the real 0x81-variable program references in the corpus).
function T.setvar_and_variable_amounts_resolve_from_player_variables()
  local player, provider = engine({
    [0] = seq({
      { op = "setvar", var = 0, amount = 1 },
      { op = "program", program = { kind = "variable", var = 0 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  })
  play(player, provider)
  local pcm = player:render(1000)
  Assert.deepEqual(
    left(pcm, 1000),
    sumSegments({ noteSegment(WAVE_B, 1, 1, 1, 1000) }, 1000),
    "the variable amount selects the program the variable names"
  )
end

-- The variable-domain arithmetic (SND_seq.c var commands): every store wraps
-- to s16, division by zero skips, the quotient truncates toward zero (a
-- negative divisor included), a negative shift moves right, and randomvar
-- draws 0..|par| with the par's sign. Table-driven: each case pins the
-- resulting variable with a conditional note through cmp_eq.
function T.variable_arithmetic_wraps_and_truncates_like_the_sdk()
  local cases = {
    { op = "addvar", init = 30000, amount = 30000, expected = -5536, rng = nil, label = "addvar wraps to s16" },
    { op = "subvar", init = -30000, amount = 30000, expected = 5536, rng = nil, label = "subvar wraps to s16" },
    { op = "mulvar", init = 20000, amount = 2, expected = -25536, rng = nil, label = "mulvar wraps to s16" },
    { op = "divvar", init = 15, amount = 4, expected = 3, rng = nil, label = "divvar truncates toward zero" },
    {
      op = "divvar",
      init = -15,
      amount = 4,
      expected = -3,
      rng = nil,
      label = "divvar truncates toward zero on a negative dividend",
    },
    {
      op = "divvar",
      init = -7,
      amount = -3,
      expected = 2,
      rng = nil,
      label = "divvar truncates toward zero on a negative divisor",
    },
    {
      op = "divvar",
      init = 7,
      amount = -3,
      expected = -2,
      rng = nil,
      label = "divvar truncates toward zero on a negative divisor and dividend",
    },
    { op = "divvar", init = 12, amount = 0, expected = 12, rng = nil, label = "divvar skips division by zero" },
    { op = "shiftvar", init = 3, amount = 2, expected = 12, rng = nil, label = "shiftvar shifts left" },
    {
      op = "shiftvar",
      init = -32768,
      amount = -4,
      expected = -2048,
      rng = nil,
      label = "a negative shift moves right (arithmetic)",
    },
    { op = "randomvar", init = 0, amount = 10, expected = 2, rng = seededRng(1), label = "randomvar draws 0..|par|" },
    {
      op = "randomvar",
      init = 0,
      amount = -10,
      expected = -2,
      rng = seededRng(1),
      label = "randomvar negates the draw for a negative par",
    },
  }
  for _, case in ipairs(cases) do
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "setvar", var = 0, amount = case.init },
        { [case.op] = true, op = case.op, var = 0, amount = case.amount },
        { op = "cmp_eq", var = 0, amount = case.expected },
        { conditional = true, op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer, rng = case.rng })
    play(player, provider)
    player:render(100)
    Assert.equal(#mixer.log.noteOns, 1, case.op .. ": " .. case.label)
  end
end

-- The transport pause (the NNS SND_PlayerPause the HGSS PlayFanfare path
-- uses): pausePlayer freezes the player's tick timeline and suspends its
-- voices -- silent, sample position frozen, no control-step pushes --
-- and resumePlayer continues the timeline exactly where it froze, so the
-- note's gate expiry and retrigger land on the original tick schedule and
-- the sample phase continues in place.
function T.pause_freezes_the_timeline_and_resume_continues_in_place()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "jump", target = 2 },
    }),
  })
  play(player, provider)
  player:render(200)
  player:pausePlayer(1)
  local held = left(player:render(600), 600)
  Assert.deepEqual(held, zeros(600), "a paused player contributes nothing")
  player:resumePlayer(1)
  -- The gate froze 300 frames short of its original expiry at frame 500, so
  -- it expires at frame 1100 and the retriggered note starts at 1101.
  local resumed = sumSegments({
    segment(waveAt(WAVE_A, 1, 801, 200), 1, 801, 1400, 1100),
    segment(waveAt(WAVE_A, 1, 1101), 1, 1101, 1400),
  }, 1400)
  Assert.deepEqual(
    left(player:render(600), 600),
    slice(resumed, 801, 1400),
    "the resumed player continues on its original tick timeline"
  )
end

-- Pause and resume follow the NNS player-state guard: pausing an unknown
-- player or an already-paused player, and resuming an unknown or unpaused
-- player, are no-ops -- a fanfare without a BGM must never fault.
function T.pause_and_resume_are_no_ops_outside_the_play_state()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  })
  player:pausePlayer(3)
  player:resumePlayer(3)
  play(player, provider)
  player:pausePlayer(1)
  player:pausePlayer(1)
  Assert.deepEqual(left(player:render(100), 100), zeros(100), "the double pause leaves the player suspended")
  player:resumePlayer(1)
  player:resumePlayer(1)
  local pcm = left(player:render(200), 200)
  Assert.isTrue(pcm[1] ~= 0 and pcm[200] ~= 0, "the resume restores the voice")
end

-- A new sequence on a paused player replaces the suspended one: the
-- replacement releases the suspended voices and they ring out -- a released
-- voice is never left suspended where no render can ever free it.
function T.playing_on_a_paused_player_releases_the_suspended_voices()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  })
  play(player, provider)
  player:render(200)
  player:pausePlayer(1)
  player:play(provider:sequence(0), provider:bank(12))
  local expected = sumSegments({
    segment(waveAt(WAVE_A, 1, 201), 1, 201, 1000, 200),
    segment(waveAt(WAVE_A, 1, 201), 8, 201, 1000),
  }, 1000)
  Assert.deepEqual(
    left(player:render(800), 800),
    slice(expected, 201, 1000),
    "the replaced voice rings its release tail under the fresh note"
  )
end

-- The per-player fader (the GameSound fade hook): setFader stores the
-- volume-domain level and the control-step push delivers its dB-domain
-- attenuation to the player's voices.
function T.the_player_fader_reaches_the_update_voice_push_in_the_db_domain()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:setFader(1, 42)
  player:render(300)
  local push
  for _, update in ipairs(mixer.log.updates) do
    if update.partial.fader ~= nil then
      push = update
    end
  end
  Assert.notNil(push, "the player pushes a fader at its control cadence")
  Assert.equal(push.partial.fader, NnsSoundMath.decibelSquare(42), "the level reaches the mixer in the dB domain")
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
    sumSegments({ noteSegment(WAVE_A, 1, 1, 1, 1000) }, 1000),
    "a true comparison runs the conditional note"
  )
  player:play(provider:sequence(1), provider:bank(12))
  local silent = player:render(1000)
  Assert.deepEqual(left(silent, 1000), zeros(1000), "a false comparison skips the conditional note")
end

return { tests = T }
