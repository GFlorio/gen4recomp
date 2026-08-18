-- SequencePlayer contract: the g4 sequence-IR interpreter on the NNS timing
-- and state model (SND_seq.c TrackStepTicks/TrackPlayNote/TrackInit/
-- TrackUpdateChannel). The tick clock is unchanged: a quarter note is 48
-- ticks, tempo is BPM (1..240, default 120), and ticks come from an exact
-- integer accumulator (tempo*48 per output frame, one tick per sampleRate*60
-- units) -- the GBATEK/ARM7 SND_TIMER_RATE relationship. A track processes
-- commands while `wait == 0` and not note-finish waiting (WAIT 0 continues
-- in the same pass); a note under note-wait gates the track for its
-- duration, and a zero-length note becomes a note-FINISH wait that holds the
-- track until its live channel handles are gone -- never a one-tick wait and
-- never a synthesized release. The player does not predict mixer death: the
-- mixer owns voice liveness (`isVoiceAlive`) and the sequencer prunes dead
-- handles from its collections and observes liveness for finish waits.
--
-- Track state follows the SDK: wait ticks, the note-finish hold, note-wait
-- (default true), a polyphonic voice collection of {handle, length} pairs,
-- tie, mute, program, priority (default 64), volume/expression 127, the raw
-- pan offset (default 0), transpose, the signed bend (default 0 -- bend 0
-- is no bend, never a centered-at-64 convention), bend range 2, the mod
-- snapshot (target 0, depth 0, range 1, speed 16, delay 0), sweepPitch 0,
-- portamentoKey 60, portamentoTime 0, the portamento flag, nullable
-- envelope stage overrides, and the call/loop stacks.
--
-- Note semantics follow TrackPlayNote: the transposed key is clamped to the
-- MIDI domain (0..127) BEFORE the bank leaf is selected, so key-split and
-- drum-set selection use the transposed key; positive finite note lengths
-- are decremented toward release while zero-length and tied channel starts
-- are indefinite and are never released by the duration counter. Pitch bend
-- is user pitch, not a key change: the spec carries `userPitch`
-- (pitchBend * (bendRange << 6) >> 7, the SDK integer shift) and held
-- voices receive userPitch updates in place. The tie command always
-- releases and frees the track's current voices even when the flag value is
-- unchanged; a tied note reuses the live head voice (key/velocity update,
-- no noteOn/noteOff). The sweep/portamento commands wire the TrackPlayNote
-- channel state (the track sweep plus the portamento contribution, the
-- sweep length from portamentoTime, autoSweep) and update portamentoKey to
-- the note's MIDI key after the note.
--
-- The player queues control changes (track values, fader, LFO parameters,
-- user pitch) to its live voices as events rather than maintaining its own
-- rounded control clock; the mixer owns the 192 Hz sound-control cadence.
-- Pause releases the player's voices with release override 127 and frees
-- the handles; the timeline freezes and resume never resurrects old voices.
-- Random amount operands resolve through the player's RNG in the SDK u16
-- draw domain (SND_CalcRandom: state = state*1664525 + 1013904223 mod 2^32,
-- draw = state >> 16, initial state 0x12345678; TrackParseValue scales
-- min + ((draw * (max - min + 1)) >> 16)); production creates the RNG once
-- and never reseeds per play.
--
-- The suite asserts events and state through a recording mixer (noteOn/
-- noteOff/updateVoice/isVoiceAlive order, handles, tick boundaries, pause
-- releases, sequence replacement); the exact PCM/register hardware math is
-- pinned in the VoiceMixer suite. The mixer's {channel, generation} handles
-- are opaque to the player: the stub mixer models the persistent-generation
-- contract. Players process ascending player number and tracks ascending
-- track number over the fixed NNS domains (16 players x 16 tracks).

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")

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
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = opts.pan or 0,
  }
end

local function square(opts)
  opts = opts or {}
  return {
    generator = { kind = "square", duty = 3 },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = opts.pan or 0,
  }
end

local function testBank()
  return AudioFixture.bank(12, "BANK_TEST", { AudioFixture.key(1), AudioFixture.key(2) }, {
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
    playerPriority = opts.playerPriority or 64,
  })
end

local function buildBundle(sequences, opts)
  opts = opts or {}
  local keyA, keyB, keyC = AudioFixture.key(1), AudioFixture.key(2), AudioFixture.key(3)
  local WAVE_C = { 500, 1000, 1500, 2000, 2500, 3000 }
  local bundle = AudioFixture.bundle()
  local indexSequences, indexPlayers, sequenceBySymbol = {}, {}, {}
  for id, sequence in pairs(sequences) do
    indexSequences[id] = {
      id = id,
      symbol = sequence.symbol,
      bankId = sequence.bankId,
      playerId = sequence.player.id,
    }
    sequenceBySymbol[sequence.symbol] = id
    indexPlayers[sequence.player.id] = {
      id = sequence.player.id,
      maxSequences = 16,
      channelMask = opts.channelMask or 0xFFFF,
    }
  end
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = { [12] = { id = 12, symbol = "BANK_TEST" } }
  bundle.index.sequenceBySymbol = sequenceBySymbol
  bundle.index.bankBySymbol = { BANK_TEST = 12 }
  bundle.sequences = sequences
  bundle.banks = { [12] = opts.bank or testBank() }
  bundle.samples = {
    [keyA] = AudioFixture.pcm16le(WAVE_A),
    [keyB] = AudioFixture.pcm16le(WAVE_B),
    [keyC] = AudioFixture.pcm16le(WAVE_C),
  }
  bundle.sampleMetadata = {
    [keyA] = AudioFixture.sampleMetadata(keyA, { frames = 8, loop = { startFrame = 0, endFrame = 8 } }),
    [keyB] = AudioFixture.sampleMetadata(keyB, { frames = 4, loop = { startFrame = 0, endFrame = 4 } }),
    [keyC] = AudioFixture.sampleMetadata(keyC, { frames = 6, loop = { startFrame = 0, endFrame = 6 } }),
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

-- Plays the test sequence. By default, renders through the first 192 Hz boundary
-- so the entry program fetches on the first sound interval (spec §9 C3, deferred entry fetch).
-- Pass mayDeferRender=true to skip the render for tests that explicitly manage rendering.
local function play(player, provider, mayDeferRender)
  player:play(provider:sequence(0), provider:bank(12))
  if not mayDeferRender then
    player:render(250)
  end
end

-- An injected RNG in the SDK u16 draw domain: returns the raw 16-bit
-- SND_CalcRandom values of a test-fixed sequence, in order.
local function u16Draws(draws)
  local index = 0
  return function()
    index = index + 1
    return draws[index]
  end
end

-- A recording mixer implementing the semantic contract the player drives:
-- noteOn returns a persistent-generation {channel, generation} handle,
-- noteOff/updateVoice/isVoiceAlive take handles, `kill` simulates the mixer
-- removing a voice (a stolen or naturally dead channel) so the player's
-- liveness-based pruning and finish waits are observable. Every call is
-- logged for assertions.
local function stubMixer()
  local log = { noteOns = {}, noteHandles = {}, noteOffs = {}, updates = {}, renders = {} }
  local generation = 0
  local alive = {}
  local mixer = {
    log = log,
    noteOn = function(_, spec)
      local gen = generation
      generation = generation + 1
      local handle = { channel = 3, generation = gen }
      log.noteOns[#log.noteOns + 1] = spec
      log.noteHandles[#log.noteHandles + 1] = handle
      alive[gen] = true
      return handle
    end,
    noteOff = function(_, handle, releaseOverride)
      log.noteOffs[#log.noteOffs + 1] = { handle = handle, releaseOverride = releaseOverride }
    end,
    updateVoice = function(_, handle, partial)
      log.updates[#log.updates + 1] = { handle = handle, partial = partial }
    end,
    isVoiceAlive = function(_, handle)
      return alive[handle.generation] == true
    end,
    kill = function(_, handle)
      alive[handle.generation] = false
    end,
    renderInto = function(_, out, frames)
      log.renders[#log.renders + 1] = frames
      for i = 1, frames * 2 do
        out[#out + 1] = 0
      end
    end,
  }
  return mixer
end

-- The generator a recorded noteOn carries; convenient for ordering and
-- instrument-selection assertions.
local function generatorOf(spec)
  return spec.generator
end

function T.plays_a_note_and_ends_the_sequence()
  local mixer = stubMixer()
  local player, provider = engine(
    { [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } }) },
    {
      mixer = mixer,
    }
  )
  local before = player:render(8)
  for i = 1, 16 do
    Assert.equal(before[i], 0, "nothing plays before play()")
  end
  play(player, provider)
  Assert.isTrue(player:isPlaying())
  player:render(500)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the 1-tick note releases at its own tick boundary"
  )
  Assert.isFalse(player:isPlaying(), "the end terminates the sequence")
end

function T.a_note_occupies_the_track_for_its_whole_duration()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 2 },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1, "the first note starts at play")
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 1, "the note's gate holds the track for its whole duration")
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the second note starts only when the first's gate opens")
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the first voice releases at its own tick boundary, before the second starts"
  )
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2), "the second note plays program 1")
end

function T.waits_gate_the_next_instruction()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "wait", duration = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 1, "the wait holds the second note until it expires")
  Assert.equal(#mixer.log.noteOffs, 1, "the first note rings its own length; the wait does not release it")
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the second note starts when the wait expires")
  player:render(500)
  Assert.isFalse(player:isPlaying())
end

function T.tempo_is_bpm_with_48_ticks_per_quarter_note()
  local function noteOffAt(tempo)
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "tempo", amount = tempo },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider, true) -- Skip auto-render to manually control frame counts
    -- Entry program fetches at first 192 Hz boundary (frame 250)
    player:render(250)
    -- Frame 250: entry fetched, note started. Render 249 more (frame 499)
    player:render(249)
    local first = #mixer.log.noteOffs
    -- Frame 500: note releases (1 tick = 250 frames after entry)
    player:render(1)
    local boundary = #mixer.log.noteOffs
    player:render(250)
    local rest = #mixer.log.noteOffs
    return first, boundary, rest
  end
  local first, boundary = noteOffAt(240)
  Assert.equal(first, 0, "at 240 BPM one tick is 250 frames; note released at frame 500 (250+250)")
  Assert.equal(boundary, 1, "the 1-tick note releases exactly 250 frames after entry fetch")
  local slowFirst, slowBoundary, slowRest = noteOffAt(120)
  Assert.equal(slowFirst, 0, "at 120 BPM one tick is 500 frames")
  Assert.equal(slowBoundary, 0, "the note survives frame 250")
  Assert.equal(slowRest, 1, "the note releases at frame 500 (48 ticks per quarter note)")
end

function T.program_changes_select_other_instruments()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the second program selects the other instrument")
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(1))
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2))
end

function T.jump_loops_back_to_its_target()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "jump", target = 2 },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 3, "the jump retriggers the note at every tick")
  Assert.equal(#mixer.log.noteOffs, 2, "each ringing voice is released at its own tick")
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
  local midMixer = stubMixer()
  local player, provider = engine({ [0] = seq(midProgram) }, { mixer = midMixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#midMixer.log.noteOns, 2, "a top-level return falls through to the next instruction like the SDK")

  local trailing = {
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "return" },
  }
  local tailMixer = stubMixer()
  local tailPlayer, tailProvider = engine({ [0] = seq(trailing) }, { mixer = tailMixer })
  play(tailPlayer, tailProvider)
  tailPlayer:render(1000)
  Assert.equal(#tailMixer.log.noteOns, 1, "a trailing top-level return falls past the program tail")
  Assert.isFalse(tailPlayer:isPlaying())
end

function T.call_and_return_execute_a_subprogram()
  local mixer = stubMixer()
  local program = {
    { op = "call", target = 4 },
    { op = "wait", duration = 1 },
    { op = "end" },
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "return" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 1, "the call returns to the instruction after it")
  Assert.isFalse(player:isPlaying())
end

function T.open_track_plays_a_second_voice_in_parallel()
  local mixer = stubMixer()
  local program = {
    { op = "open_track", track = 1, target = 5 },
    { op = "program", program = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
    { op = "program", program = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1, "the main track notes at play")
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the opened track notes on the first render pass")
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2))
  Assert.isFalse(player:isPlaying(), "the sequence ends when every track ends")
end

-- The volume/expression commands ride the note spec as the SDK fields; the
-- dB-domain register conversion they feed is VoiceMixer contract (the
-- player never folds them together).
function T.volume_and_expression_ride_the_note_spec()
  local function specFor(prefix)
    local mixer = stubMixer()
    local player, provider = engine({ [0] = seq(prefix) }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    return mixer.log.noteOns[1]
  end
  local expression = specFor({
    { op = "expression", amount = 64 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(expression.expression, 64, "the expression command sets the note's expression field")
  local volume = specFor({
    { op = "volume", amount = 64 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(volume.trackVolume, 64, "the volume command sets the track volume field")
  local silent = specFor({
    { op = "expression", amount = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  })
  Assert.equal(silent.expression, 0, "expression 0 is passed through as zero")
end

-- Transpose is the SDK s8 (0x80 lowers to -128, 0xFF to -1): the note key
-- plus transpose is clamped to the MIDI domain 0..127, and the clamped key
-- drives the bank leaf selection (SND_seq.c TrackStepTicks midiKey +
-- TrackPlayNote SND_ReadInstData), never the raw source key.
function T.transpose_shifts_the_note_key_by_signed_semitones()
  local function noteFor(transpose, key, program)
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "program", program = program },
        { op = "transpose", amount = transpose },
        { op = "note", key = key, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    return mixer.log.noteOns[1]
  end
  local down = noteFor(-128, 60, 2)
  Assert.equal(down.key, 0, "key 60 + transpose -128 clamps to midi key 0")
  Assert.equal(generatorOf(down).sample, AudioFixture.key(1), "midi key 0 selects the low key-split range")
  local up = noteFor(127, 60, 2)
  Assert.equal(up.key, 127, "key 60 + transpose 127 clamps to midi key 127")
  Assert.equal(generatorOf(up).sample, AudioFixture.key(2), "midi key 127 selects the high key-split range")
  local edge = noteFor(-1, 0, 2)
  Assert.equal(edge.key, 0, "key 0 + transpose -1 clamps to midi key 0")
  Assert.equal(generatorOf(edge).sample, AudioFixture.key(1))
end

-- Random operands resolve through the default SDK RNG (SND_CalcRandom:
-- state = state*1664525 + 1013904223 mod 2^32, initial state 0x12345678,
-- draw = the high 16 bits of state) with the TrackParseValue integer
-- scaling min + ((draw * (max - min + 1)) >> 16). The player creates the
-- RNG once at construction and never reseeds per play, so consecutive
-- plays draw consecutive SDK values. Known vectors (computed from the SDK
-- formula): draws 0x7543, 0xCD30, 0x25DB for the pan range 0..127 map to
-- pan 58, 102, 18 (offsets -6, 38, -46).
function T.random_operands_draw_from_the_default_sdk_rng_without_reseeding()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "pan", amount = { kind = "random", min = 0, max = 127 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(10)
  Assert.equal(
    mixer.log.noteOns[1].trackPanOffset,
    -6,
    "the first SDK draw 0x7543 = 30019 scales (30019*128)>>16 = 58 -> offset -6"
  )
  play(player, provider)
  Assert.equal(
    mixer.log.noteOns[2].trackPanOffset,
    38,
    "the second draw 0xCD30 = 52528 scales to pan 102, and the state persisted across plays"
  )
  play(player, provider)
  Assert.equal(mixer.log.noteOns[3].trackPanOffset, -46, "the third draw 0x25DB = 9691 scales to pan 18")
end

-- The injected RNG is in the same u16 draw domain as the production RNG (a
-- function returning the raw 16-bit draw), and the operand scales the draw
-- with the SDK integer arithmetic -- never a 0..1 float.
function T.random_operands_scale_the_u16_draw_with_sdk_integer_arithmetic()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "pan", amount = { kind = "random", min = 0, max = 127 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer, rng = u16Draws({ 0x0000, 0x8000, 0xFFFF, 0x4000 }) })
  play(player, provider)
  player:render(10)
  Assert.equal(mixer.log.noteOns[1].trackPanOffset, -64, "draw 0x0000 scales to pan 0")
  play(player, provider)
  Assert.equal(mixer.log.noteOns[2].trackPanOffset, 0, "draw 0x8000 = 32768 scales (32768*128)>>16 = 64")
  play(player, provider)
  Assert.equal(mixer.log.noteOns[3].trackPanOffset, 63, "draw 0xFFFF = 65535 scales to pan 127")
  play(player, provider)
  Assert.equal(mixer.log.noteOns[4].trackPanOffset, -32, "draw 0x4000 = 16384 scales to pan 32")
end

function T.the_player_initial_volume_passes_through_as_player_volume()
  local function playerVolume(initialVolume)
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq(
        { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } },
        { initialVolume = initialVolume }
      ),
    }, { mixer = mixer })
    play(player, provider)
    player:render(100)
    return mixer.log.noteOns[1].playerVolume
  end
  Assert.equal(playerVolume(127), 127, "the player volume passes through, never folded into the track volume")
  Assert.equal(playerVolume(64), 64)
end

function T.playing_on_the_same_player_replaces_the_sequence()
  local mixer = stubMixer()
  local first =
    { { op = "program", program = 0 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local second =
    { { op = "program", program = 1 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local player, provider = engine({
    [0] = seq(first),
    [1] = seq(second, { id = 1, symbol = "SEQ_TEST_B", playerId = 1 }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(1))
  player:play(provider:sequence(1), provider:bank(12))
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the replacement releases the previous sequence's voices"
  )
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2))
end

function T.sequences_on_different_players_mix()
  local mixer = stubMixer()
  local programA =
    { { op = "program", program = 0 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local programB =
    { { op = "program", program = 1 }, { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }
  local player, provider = engine({
    [0] = seq(programA, { playerId = 1 }),
    [1] = seq(programB, { id = 1, symbol = "SEQ_TEST_B", playerId = 2 }),
  }, { mixer = mixer })
  player:play(provider:sequence(0), provider:bank(12))
  player:play(provider:sequence(1), provider:bank(12))
  Assert.equal(#mixer.log.noteOns, 2, "two players mix like two hardware players")
  player:render(1000)
  Assert.equal(#mixer.log.noteOffs, 2, "both players' voices release at their own tick")
  Assert.isFalse(player:isPlaying())
end

function T.stop_releases_all_voices()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({ { op = "note", key = 60, velocity = 127, duration = 2 }, { op = "end" } }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(200)
  player:stop()
  Assert.isFalse(player:isPlaying())
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "stop releases every active voice"
  )
  player:render(400)
  Assert.equal(#mixer.log.noteOns, 1, "no new notes issue after stop")
end

-- The batched render contract: the player asks the mixer for spans that
-- end at the next event boundary (a control event, a sequence tick, the
-- buffer end) instead of one frame at a time. The mixer call count must
-- stay far below one per frame over a 1000-frame render (the exact
-- partition is implementation-owned; the upper bound is the performance
-- contract).
function T.the_player_renders_mixer_spans_until_event_boundaries()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  local total = 0
  for _, frames in ipairs(mixer.log.renders) do
    total = total + frames
  end
  Assert.equal(total, 1000, "the mixer spans partition the requested window exactly")
  Assert.isTrue(#mixer.log.renders <= 5, "one span per event boundary at most, never one call per frame")
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
  Assert.deepEqual(one, playChunked({ 1000, 1000 }), "render(1000)+render(1000) equals render(2000)")
  Assert.deepEqual(one, playChunked({ 400, 600, 1000 }), "render(400)+render(600)+render(1000) equals render(2000)")
  Assert.deepEqual(
    one,
    playChunked({ 250, 250, 250, 250, 250, 250, 250, 250 }),
    "splits at the control-period boundary stay byte-identical"
  )
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
  -- references placeholder/unused instruments that the DS plays as silence,
  -- never as a fault. The silent note still gates the track.
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 9 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(600)
  Assert.equal(#mixer.log.noteOns, 0, "a missing instrument is a silent note")
  Assert.isFalse(player:isPlaying())
end

-- A structurally valid program that can never reach `end` (a self-loop) must
-- not hang the host: the step-budget failure is the player's host-safety
-- boundary and stays even though no retail sequence triggers it. Malformed
-- IR is excluded before it reaches the player -- the closed sequence
-- validator (libs/assets AudioSequence, AUDIO_SEQUENCE_INVALID) owns unknown
-- ops and illegal operand shapes at the asset boundary, so feeding them to
-- the player directly is not a contract here.
function T.runaway_loops_hit_the_host_safety_budget()
  throwsCode("AUDIO_PLAYER_UNBOUNDED_EXECUTION", function()
    local player, provider = engine({ [0] = seq({ { op = "jump", target = 1 } }) })
    play(player, provider)
    player:render(10)
  end)
end

function T.key_split_instruments_select_by_note_key()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 2 },
    { op = "note", key = 30, velocity = 127, duration = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(1), "key 30 hits the low range")
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2), "key 60 hits the high range")
end

function T.drum_set_voices_select_by_key_and_out_of_range_is_silent()
  local mixer = stubMixer()
  local program = {
    { op = "program", program = 3 },
    { op = "note", key = 35, velocity = 127, duration = 1 },
    { op = "note", key = 36, velocity = 127, duration = 1 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1500)
  Assert.deepEqual(
    mixer.log.noteOns[1].generator,
    { kind = "sample", sample = AudioFixture.key(1) },
    "drum 35 plays the sample voice"
  )
  Assert.deepEqual(mixer.log.noteOns[2].generator, { kind = "square", duty = 3 }, "drum 36 plays the square")
  Assert.equal(#mixer.log.noteOns, 2, "key 60 is out of the drum range and silent")
end

-- The transposed, clamped MIDI key drives instrument leaf selection (the
-- NNS TrackStepTicks midiKey plus TrackPlayNote SND_ReadInstData path): a
-- note crossing a key-split boundary after transposition must play the
-- range the transposed key lands in, never the source key's voice pitched
-- up.
function T.transpose_moves_key_split_selection_across_the_boundary()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 2 },
      { op = "transpose", amount = 5 },
      { op = "note", key = 55, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.deepEqual(
    mixer.log.noteOns[1].generator,
    { kind = "sample", sample = AudioFixture.key(2) },
    "key 55 + transpose 5 = 60 crosses the split at 60 and selects the high range voice"
  )
  Assert.equal(mixer.log.noteOns[1].key, 60, "the voice pitch is the transposed key")
end

-- The same contract holds across a drum-set boundary: the transposed key
-- indexes the drum voices, and a transposition out of the drum range is
-- silent (a drum-set miss, not a stale source-key voice).
function T.transpose_moves_drum_selection_across_the_boundary()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 3 },
      { op = "transpose", amount = 1 },
      { op = "note", key = 35, velocity = 127, duration = 1 },
      { op = "note", key = 36, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.deepEqual(
    mixer.log.noteOns[1].generator,
    { kind = "square", duty = 3 },
    "key 35 + transpose 1 = 36 selects the drum voice at key 36"
  )
  Assert.equal(mixer.log.noteOns[1].key, 36, "the drum voice pitches at the transposed key")
  Assert.equal(#mixer.log.noteOns, 1, "key 36 + transpose 1 = 37 leaves the drum range and is silent")
end

function T.loop_begin_and_loop_end_repeat_the_body()
  local mixer = stubMixer()
  local program = {
    { op = "loop_begin", count = 2 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "loop_end" },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 2, "count 2 runs the body twice (the SDK decrements at loop_end and exits at zero)")
  Assert.equal(#mixer.log.noteOffs, 2, "each iteration's voice rings its own length")
  Assert.isFalse(player:isPlaying())
end

-- The SDK's loopCount 0 never decrements: loop_end jumps back forever, so a
-- count-0 loop rings until the sequence is stopped (the real
-- SEQ_GS_P_SAFARI_ROAD map music).
function T.loop_begin_count_zero_loops_forever()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "loop_begin", count = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "loop_end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(2000)
  Assert.equal(#mixer.log.noteOns, 5, "count 0 re-enters the body on every tick")
  Assert.isTrue(player:isPlaying(), "a count-0 loop never ends on its own")
end

-- The SDK's 0xFC with no active loop frame (call depth 0) is a no-op; the
-- real corpus contains tracks whose loop code is dead bytes, so an
-- unmatched loop_end must fall through without faulting.
function T.unmatched_loop_end_is_a_no_op()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "loop_end" },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 1, "the unmatched loop_end falls through")
  Assert.isFalse(player:isPlaying())
end

-- WAIT 0 must not delay execution to the next tick: the SDK command loop
-- continues while `wait == 0 && !note_finish_wait`, so the next command runs
-- in the same processing pass as the gate that released it.
function T.wait_zero_runs_the_next_command_in_the_same_pass()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(500)
  Assert.equal(
    #mixer.log.noteOns,
    2,
    "the second note starts in the same pass as the WAIT 0 executes, at the first tick"
  )
end

-- A silent zero-length note (an instrument the bank does not define has no
-- channel to wait for) still sets the note-finish wait; with no live
-- handles the wait clears at the FIRST tick (the SDK TrackStepTicks
-- note_finish_wait check runs per tick, never one frame early), and the
-- following note starts on the frame after that tick.
function T.silent_zero_length_notes_release_their_gate_at_the_first_tick()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 9 },
      { op = "note", key = 60, velocity = 127, duration = 0 },
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 0, "the silent note sounds nothing and the marker has not started")
  player:render(1)
  Assert.equal(#mixer.log.noteOns, 1, "the marker note starts on the frame after the first tick")
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(1))
end

-- A zero-length note under note-wait is a note-FINISH wait (SND_seq.c
-- TrackPlayNote): the channel starts with an indefinite length (it is never
-- released merely because a sequence tick elapsed) and the track holds
-- until the mixer reports its live handles gone. The recording mixer's
-- kill() models the mixer removing the voice (stolen or naturally dead);
-- the marker note must not start until that happens.
function T.zero_length_notes_wait_for_real_handle_liveness()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 0 },
      { op = "program", program = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  local handle = mixer.log.noteHandles[1]
  Assert.equal(#mixer.log.noteOns, 1, "the zero-length note starts one voice")
  player:render(500)
  Assert.equal(
    #mixer.log.noteOffs,
    0,
    "a zero-length note's voice is indefinite: one elapsed tick must never release it"
  )
  Assert.equal(#mixer.log.noteOns, 1, "the marker note is still held while the voice lives")
  mixer:kill(handle)
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 2, "the finish wait observes the dead handle and releases the track")
  Assert.equal(generatorOf(mixer.log.noteOns[2]).sample, AudioFixture.key(2))
end

-- The NNS track polyphony: with note-wait cleared, overlapping notes all
-- sound; each voice rings its own channel length independently. The track's
-- voice collection is a list of {channel, generation} handles -- never a
-- single channel.
function T.overlapping_notes_form_a_polyphonic_voice_collection()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "both notes allocate in the first pass")
  player:render(1000)
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "each voice rings its own length and releases at its own tick")
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
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the first voice's length expires at its own tick"
  )
  player:render(500)
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "the second voice's length expires on its own later tick")
end

-- The mixer owns voice liveness: the track's collection is pruned by
-- `mixer:isVoiceAlive` (a stolen or naturally dead handle leaves the
-- collection), so a later release (a tie command) touches only the live
-- voices and never issues a stale noteOff.
function T.dead_handles_are_pruned_by_mixer_liveness()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "note", key = 61, velocity = 127, duration = 4 },
      { op = "wait", duration = 2 },
      { op = "tie", amount = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "two voices ring in parallel")
  player:render(500)
  mixer:kill(mixer.log.noteHandles[1])
  player:render(500)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 1 }, releaseOverride = nil } },
    "the tie releases only the live voice; the dead handle was pruned by liveness"
  )
end

-- The NNS tie (SND_seq.c 0xC8 TrackReleaseChannels + TrackFreeChannels):
-- the tie command itself always releases and frees the track's current
-- voices, even when the new flag equals the previous flag. A repeated
-- same-value `tie 1` still releases whatever is ringing.
function T.repeated_tie_one_still_releases_current_voices()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "tie", amount = 1 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "tie", amount = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "the first tie frees the old voice and the next note starts a new one")
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "both ties release: the flag was already true for the second, and it still frees the current voice")
end

-- A tied channel starts with an indefinite length (TrackPlayNote), so it
-- survives past any supplied note duration; a later tied note over the live
-- head voice reuses it in place (key/velocity update, no noteOn, no
-- noteOff), and clearing the tie releases the reused voice.
function T.tied_voices_survive_their_duration_and_reuse_the_live_head()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "tie", amount = 1 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "note", key = 61, velocity = 127, duration = 1 },
      { op = "wait", duration = 1 },
      { op = "tie", amount = 0 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 1, "the tied note starts one voice")
  player:render(500)
  Assert.equal(#mixer.log.noteOffs, 0, "a tied voice is indefinite: it survives past its supplied one-tick duration")
  Assert.equal(#mixer.log.noteOns, 1, "the tied re-note reuses the live head: no new allocation")
  Assert.equal(#mixer.log.updates, 1, "the tied re-note updates the live head in place instead of restarting it")
  Assert.deepEqual(mixer.log.updates[1].handle, { channel = 3, generation = 0 })
  Assert.equal(mixer.log.updates[1].partial.key, 61, "the reuse updates the voice's key")
  Assert.equal(mixer.log.updates[1].partial.velocity, 127, "the reuse updates the voice's velocity")
  player:render(500)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "clearing tie releases and frees the reused tied voice"
  )
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
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
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

-- The voice spec is the semantic mixer contract: trackVolume + playerVolume
-- (never folded), trackPriority + playerPriority, the raw trackPanOffset,
-- the instrument pan, the clamped transposed key, the TrackInit defaults
-- (bend 0 -> userPitch 0), the TrackPlayNote sweep fields, the
-- TrackUpdateChannel lfo snapshot, and a {channel, generation} handle
-- back. The derived sample metadata has no source sample rate, and the spec
-- does not carry one either.
function T.note_spec_carries_the_semantic_mixer_contract()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq(
      { { op = "note", key = 64, velocity = 96, duration = 1 }, { op = "end" } },
      { initialVolume = 100, playerPriority = 16 }
    ),
  }, { mixer = mixer })
  play(player, provider)
  player:render(500)
  Assert.equal(#mixer.log.noteOns, 1, "one note, one voice command")
  local spec = mixer.log.noteOns[1]
  Assert.deepEqual(spec.generator, { kind = "sample", sample = AudioFixture.key(1) })
  Assert.deepEqual(spec.pcm, WAVE_A, "the mixer receives the provider-decoded PCM array")
  Assert.deepEqual(spec.loop, { startFrame = 0, endFrame = 8 })
  Assert.equal(spec.loopEnabled, true, "the mixer receives the wave's loop flag")
  Assert.equal(spec.baseTimer, 8006, "the mixer receives the wave's DS base timer")
  Assert.isNil(spec.sampleRate, "the voice spec carries no source sample rate (playback is the DS clock path)")
  Assert.equal(spec.key, 64, "the note key is the midi key (no bend fold)")
  Assert.equal(spec.userPitch, 0, "bend 0 is no bend: the TrackInit user pitch")
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
  Assert.isNil(spec.bend, "bend is userPitch; the mixer spec has no bend field")
  Assert.deepEqual(
    spec.lfo,
    { target = 0, depth = 0, range = 1, speed = 16, delay = 0 },
    "the spec always carries the lfo snapshot with the TrackInit defaults (SND_InitLfoParam)"
  )
  Assert.equal(spec.sweepPitch, 0, "the spec always carries the track sweep pitch (TrackInit 0)")
  Assert.equal(spec.sweepLength, 1, "portamentoTime 0 makes the note length the sweep length")
  Assert.equal(spec.autoSweep, false, "portamentoTime 0 disables the autoSweep advance (TrackPlayNote)")
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
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
    }, { playerPriority = 16 }),
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

-- Pitch bend is signed s8 (0 = no bend) and rides the spec as user pitch
-- (SND_seq.c TrackUpdateChannel: userPitch = pitchBend * (bendRange << 6)
-- >> 7, an arithmetic shift), never as a key change and never centered at
-- 64. The odd-product cases pin the floor semantics of the signed shift
-- (bend 67 at range 3 folds (67*192)>>7 = 100, bend -67 folds
-- (-67*192)>>7 = -101).
function T.pitch_bend_is_signed_user_pitch_not_a_key_fold()
  local mixer = stubMixer()
  local program = {
    { op = "note_wait", amount = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend_range", amount = 2 },
    { op = "pitch_bend", amount = 1 },
    { op = "note", key = 61, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = 0 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = -64 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = 127 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = -128 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend_range", amount = 3 },
    { op = "pitch_bend", amount = 67 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = 61 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "pitch_bend", amount = -67 },
    { op = "note", key = 60, velocity = 127, duration = 1 },
    { op = "end" },
  }
  local player, provider = engine({ [0] = seq(program) }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  local specs = mixer.log.noteOns
  Assert.equal(#specs, 9, "the bend commands gate nothing")
  Assert.equal(specs[1].key, 60, "bend defaults to 0: the key is the note key")
  Assert.equal(specs[1].userPitch, 0, "bend 0 is no bend")
  Assert.equal(specs[2].key, 61, "bend never changes the midi key")
  Assert.equal(specs[2].userPitch, 1, "bend 1 at range 2: (1*128)>>7 = 1")
  Assert.equal(specs[3].userPitch, 0, "pitch_bend 0 produces exactly no bend")
  Assert.equal(specs[4].userPitch, -64, "bend -64 at range 2: (-64*128)>>7 = -64")
  Assert.equal(specs[5].userPitch, 127, "bend 127 at range 2: (127*128)>>7 = 127")
  Assert.equal(specs[6].userPitch, -128, "bend 0x80 lowered to -128: (-128*128)>>7 = -128")
  Assert.equal(specs[7].key, 60, "bend never moves the key across the odd-product rows either")
  Assert.equal(specs[7].userPitch, 100, "bend 67 at range 3: (67*192)>>7 = 100")
  Assert.equal(specs[8].userPitch, 91, "bend 61 at range 3: (61*192)>>7 = 91")
  Assert.equal(specs[9].userPitch, -101, "bend -67 at range 3: the arithmetic shift floors (-67*192)>>7 = -101")
end

-- Pitch bend reaches an already-active held voice as a userPitch update --
-- never as a MIDI-key replacement (SND_seq.c TrackUpdateChannel per main).
function T.held_voices_receive_pitch_bend_updates_in_place()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "pitch_bend_range", amount = 2 },
      { op = "pitch_bend", amount = 64 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(mixer.log.noteOns[1].userPitch, 0, "the note starts at the unbent pitch")
  player:render(100)
  Assert.isTrue(#mixer.log.updates > 0, "the bend change is queued to the active voice")
  local push = mixer.log.updates[1]
  Assert.deepEqual(push.handle, { channel = 3, generation = 0 }, "the update targets the active voice's handle")
  Assert.equal(push.partial.userPitch, 64, "the bend reaches the held voice as user pitch (64*128>>7 = 64)")
  Assert.isNil(push.partial.key, "the update changes pitch without replacing the voice's midi key")
end

-- The player queues control changes (volume, pan, expression, fader, LFO,
-- user pitch) to its live voices as events; it has no independently rounded
-- control clock of its own -- the mixer owns the 192 Hz cadence -- so a
-- value change becomes audible at the next mixer control step without
-- waiting for a player-side period boundary.
function T.track_value_changes_reach_active_voices_promptly()
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
  player:render(100)
  Assert.isTrue(#mixer.log.updates > 0, "the changed values reach the active voice within the first control period")
  local push
  for _, update in ipairs(mixer.log.updates) do
    if
      update.partial.trackVolume == 60
      and update.partial.expression == 80
      and update.partial.trackPanOffset == -24
    then
      push = update
    end
  end
  Assert.notNil(push, "the push carries the current track volume, expression and raw pan offset")
  Assert.deepEqual(push.handle, { channel = 3, generation = 0 }, "the push targets the active voice's handle")
  Assert.equal(push.partial.playerVolume, 127, "the push carries the player volume too")
end

-- Deterministic scheduling: the player processes players ascending and each
-- player's tracks ascending over the fixed NNS domains (16 players x 16
-- tracks per player). Within every processing pass the lower track numbers
-- issue their noteOn first.
function T.contested_allocation_follows_ascending_track_order()
  local bank = AudioFixture.bank(12, "BANK_TEST", {
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
  local mixer = stubMixer()
  local player, provider = engine({ [0] = seq(program, { symbol = "SEQ_CONTEST" }) }, {
    bank = bank,
    channelMask = 0x0010,
    mixer = mixer,
  })
  play(player, provider)
  player:render(1000)
  Assert.equal(#mixer.log.noteOns, 6, "each tick notes tracks 0, 9 and 15 once (the sub-tracks open gated)")
  Assert.equal(mixer.log.noteOns[1].channelMask, 0x0010, "the sequence's player channel mask rides the note specs")
  for i = 1, 6 do
    local expected = ({ AudioFixture.key(1), AudioFixture.key(2), AudioFixture.key(3) })[((i - 1) % 3) + 1]
    Assert.equal(
      generatorOf(mixer.log.noteOns[i]).sample,
      expected,
      "every pass notes tracks 0, 9, 15 in ascending track order"
    )
  end
end

-- Deterministic scheduling across players: different play orders must not
-- change the per-tick processing order, which is ascending player number
-- over the fixed NNS domain, never Lua table order. Only the initial play()
-- pass follows the call order; from the first tick on every pass is
-- identical.
function T.contested_allocation_is_identical_across_player_play_orders()
  local bank = AudioFixture.bank(12, "BANK_TEST", {
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
    local mixer = stubMixer()
    local provider = AudioAssetProvider.new(AudioFixture.readyCache(buildBundle(sequences, {
      bank = bank,
      channelMask = 0x0010,
    })))
    local player = SequencePlayer.new({
      sampleRate = SAMPLE_RATE,
      mixer = mixer,
      provider = provider,
    })
    for _, index in ipairs(order) do
      player:play(provider:sequence(index), provider:bank(12))
    end
    player:render(1000)
    return mixer
  end
  local forward = run({ 0, 1, 2, 3 })
  local backward = run({ 3, 2, 1, 0 })
  Assert.equal(#forward.log.noteOns, 12, "the four initial noteOns plus one per player per tick (two ticks)")
  Assert.equal(#backward.log.noteOns, 12)
  for i = 9, 12 do
    local expected = ({ AudioFixture.key(1), AudioFixture.key(2) })[((i - 9) % 2) + 1]
    Assert.equal(
      generatorOf(forward.log.noteOns[i]).sample,
      generatorOf(backward.log.noteOns[i]).sample,
      "from the first tick on, the per-pass player order is identical regardless of play order"
    )
    Assert.equal(
      generatorOf(forward.log.noteOns[i]).sample,
      expected,
      "the ascending player order hands the pass to players 1, 7, 13, 15"
    )
  end
end

-- The full NNS track domain: all 16 tracks of a player run, and every note
-- carries the semantic spec.
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
-- releases exactly that player's voices.
function T.stop_player_releases_only_that_player()
  local mixer = stubMixer()
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
  local player, provider = engine({ [0] = bgm, [1] = effect }, { mixer = mixer })
  player:play(provider:sequence(0), provider:bank(12))
  player:play(provider:sequence(1), provider:bank(12))
  player:render(200)
  Assert.isTrue(player:isPlayerPlaying(1))
  Assert.isTrue(player:isPlayerPlaying(2))
  player:stopPlayer(2)
  Assert.isFalse(player:isPlayerPlaying(2), "the stopped player reports free")
  Assert.isTrue(player:isPlayerPlaying(1), "the other player keeps running")
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 1 }, releaseOverride = nil } },
    "only the stopped player's voice is released"
  )
  player:render(300)
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
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "wait", duration = 1 },
      { op = "wait", duration = 1 },
      { op = "wait", duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(1000)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "a note whose gating is cleared rings exactly its own duration; the waits gate without releasing it"
  )
  player:render(500)
  Assert.isFalse(player:isPlaying(), "end terminates the track")
end

-- The sweep/portamento commands wire the TrackPlayNote channel state into
-- the noteOn spec (SND_seq.c): 0xE3 sweep stores the s16 track sweepPitch;
-- 0xC9 portamento_key stores amount + transpose and sets the portamento
-- flag; a noteOn while portamento is on adds (portamentoKey - midiKey) << 6
-- pitch units; portamentoTime 0 carries the note length as sweepLength with
-- autoSweep false, a nonzero time carries
-- portamentoTime^2 * |sweepPitch| >> 11 with autoSweep true; 0xCE
-- portamento 0 clears the flag and the contribution. After each note the
-- track's portamentoKey is updated to the note's MIDI key, so the next
-- portamento contribution slides from the just-played pitch.
function T.sweep_and_portamento_commands_wire_the_note_sweep_spec()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "sweep", amount = -100 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "portamento_key", amount = 64 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "portamento_time", amount = 8 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "portamento", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "portamento", amount = 1 },
      { op = "transpose", amount = -12 },
      { op = "portamento_key", amount = 64 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "note", key = 61, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  local specs = mixer.log.noteOns
  Assert.equal(#specs, 7, "the commands gate nothing: every note allocates in the first pass")
  Assert.deepEqual(
    { sweepPitch = specs[1].sweepPitch, sweepLength = specs[1].sweepLength, autoSweep = specs[1].autoSweep },
    { sweepPitch = 0, sweepLength = 1, autoSweep = false },
    "a fresh track: no sweep, portamentoTime 0 makes the note length the sweep length"
  )
  Assert.deepEqual(
    { sweepPitch = specs[2].sweepPitch, sweepLength = specs[2].sweepLength, autoSweep = specs[2].autoSweep },
    { sweepPitch = -100, sweepLength = 1, autoSweep = false },
    "the sweep command sets the track sweepPitch; the next noteOn's spec carries it"
  )
  Assert.deepEqual(
    { sweepPitch = specs[3].sweepPitch, sweepLength = specs[3].sweepLength, autoSweep = specs[3].autoSweep },
    { sweepPitch = -100 + (64 - 60) * 64, sweepLength = 1, autoSweep = false },
    "portamento_key 64 adds (portamentoKey - midiKey) << 6 = 256 to the track sweep"
  )
  Assert.deepEqual(
    { sweepPitch = specs[4].sweepPitch, sweepLength = specs[4].sweepLength, autoSweep = specs[4].autoSweep },
    { sweepPitch = -100, sweepLength = 3, autoSweep = true },
    "the previous note updated portamentoKey to midi key 60, so this note adds no contribution (8^2*100>>11 = 3)"
  )
  Assert.deepEqual(
    { sweepPitch = specs[5].sweepPitch, sweepLength = specs[5].sweepLength, autoSweep = specs[5].autoSweep },
    { sweepPitch = -100, sweepLength = 3, autoSweep = true },
    "portamento 0 clears the flag: the note carries only the track sweep"
  )
  Assert.deepEqual(
    { sweepPitch = specs[6].sweepPitch, sweepLength = specs[6].sweepLength, autoSweep = specs[6].autoSweep },
    { sweepPitch = -100 + (52 - 48) * 64, sweepLength = 4, autoSweep = true },
    "portamento_key stores amount + transpose (52); the note's midiKey is 48, so the contribution is still 256"
  )
  Assert.deepEqual(
    { sweepPitch = specs[7].sweepPitch, sweepLength = specs[7].sweepLength, autoSweep = specs[7].autoSweep },
    { sweepPitch = -100 + (48 - 49) * 64, sweepLength = 5, autoSweep = true },
    "portamentoKey was updated to the previous note's midi key 48; the key-61 note slides down (8^2*164>>11 = 5)"
  )
end

-- The mod commands wire the TrackUpdateChannel lfo snapshot (SND_seq.c
-- 0xCA-0xCD, 0xE0) into the next noteOn's spec with the TrackInit defaults
-- (SND_InitLfoParam) when unset. The commands gate nothing and release
-- nothing.
function T.mod_commands_wire_the_note_lfo_spec()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "mod_depth", amount = 100 },
      { op = "mod_speed", amount = 10 },
      { op = "mod_type", amount = 1 },
      { op = "mod_range", amount = 3 },
      { op = "mod_delay", amount = 16 },
      { op = "note", key = 60, velocity = 127, duration = 2 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  Assert.equal(#mixer.log.noteOns, 2, "the mod commands gate nothing: both notes allocate in the first pass")
  Assert.equal(#mixer.log.noteOffs, 0, "the mod commands release nothing")
  Assert.deepEqual(
    mixer.log.noteOns[1].lfo,
    { target = 0, depth = 0, range = 1, speed = 16, delay = 0 },
    "an unset mod is the TrackInit lfo (SND_InitLfoParam)"
  )
  Assert.deepEqual(
    mixer.log.noteOns[2].lfo,
    { target = 1, depth = 100, range = 3, speed = 10, delay = 16 },
    "mod_depth/mod_speed/mod_type/mod_range/mod_delay wire the lfo snapshot"
  )
  player:render(500)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = nil } },
    "the first voice's own length expires at its tick"
  )
  player:render(500)
  Assert.deepEqual(mixer.log.noteOffs, {
    { handle = { channel = 3, generation = 0 }, releaseOverride = nil },
    { handle = { channel = 3, generation = 1 }, releaseOverride = nil },
  }, "the second voice rings its own longer length")
  Assert.isFalse(player:isPlaying(), "the sequence ends after the notes ring out")
end

-- Modulation commands change active voice behavior: the changed LFO
-- parameters are queued to the ringing voice's handle so the mixer's LFO
-- applies them at its control steps -- the player does not advance LFOs
-- itself.
function T.modulation_commands_update_active_voices()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "note_wait", amount = 0 },
      { op = "note", key = 60, velocity = 127, duration = 4 },
      { op = "mod_depth", amount = 64 },
      { op = "mod_speed", amount = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.isTrue(#mixer.log.updates > 0, "the LFO change reaches the active voice")
  Assert.deepEqual(mixer.log.updates[1].handle, { channel = 3, generation = 0 })
  Assert.deepEqual(
    mixer.log.updates[1].partial.lfo,
    { target = 0, depth = 64, range = 1, speed = 8, delay = 0 },
    "the queued partial carries the updated LFO parameters"
  )
end

-- 0xB0 `setvar` writes player variables and variable amount operands read
-- them back (the real 0x81-variable program references in the corpus).
function T.setvar_and_variable_amounts_resolve_from_player_variables()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "setvar", var = 0, amount = 1 },
      { op = "program", program = { kind = "variable", var = 0 } },
      { op = "note", key = 60, velocity = 127, duration = 1 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(100)
  Assert.equal(generatorOf(mixer.log.noteOns[1]).sample, AudioFixture.key(2), "the variable amount selects the program")
end

-- The variable-domain arithmetic (SND_seq.c var commands): every store
-- wraps to s16, division by zero skips, the quotient truncates toward zero
-- (a negative divisor included), a negative shift moves right, signed s16
-- operands (0xFFFF lowers to -1) take part in the same arithmetic, and
-- randomvar draws the SDK u16 value and scales (random * (abs(par)+1)) >> 16
-- with the par's sign. The resulting variable is observed through a pan
-- amount operand (the note spec's trackPanOffset is var - 64).
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
    { op = "addvar", init = 5, amount = -1, expected = 4, rng = nil, label = "0xFFFF adds as -1 (s16 operand)" },
    { op = "mulvar", init = 5, amount = -1, expected = -5, rng = nil, label = "0xFFFF multiplies as -1" },
    { op = "divvar", init = 15, amount = -1, expected = -15, rng = nil, label = "0xFFFF divides as -1" },
    { op = "shiftvar", init = 4, amount = -1, expected = 2, rng = nil, label = "0xFFFF is a negative (right) shift" },
    {
      op = "randomvar",
      init = 0,
      amount = 10,
      expected = 5,
      rng = u16Draws({ 30019 }),
      label = "randomvar scales the u16 draw (30019*11)>>16 = 5",
    },
    {
      op = "randomvar",
      init = 0,
      amount = -10,
      expected = -5,
      rng = u16Draws({ 30019 }),
      label = "randomvar negates the draw for a negative par",
    },
  }
  for _, case in ipairs(cases) do
    local mixer = stubMixer()
    local player, provider = engine({
      [0] = seq({
        { op = "setvar", var = 0, amount = case.init },
        { op = case.op, var = 0, amount = case.amount },
        { op = "pan", amount = { kind = "variable", var = 0 } },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      }),
    }, { mixer = mixer, rng = case.rng })
    play(player, provider)
    player:render(100)
    Assert.equal(mixer.log.noteOns[1].trackPanOffset, case.expected - 64, case.op .. ": " .. case.label)
  end
end

-- The transport pause (the NNS SND_PlayerPause the HGSS PlayFanfare path
-- uses): pausePlayer marks the timeline paused and releases the player's
-- current channel handles with release override 127, freeing them from the
-- tracks. While paused the timeline does not advance and no notes issue;
-- resumePlayer only unpauses the timeline and never resurrects the released
-- voices.
function T.pause_releases_channels_with_an_override_and_resume_does_not_resurrect()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(200)
  player:pausePlayer(1)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "pause releases the player's channels with the forced release override"
  )
  player:render(6000)
  Assert.equal(#mixer.log.noteOns, 1, "no notes issue while paused")
  Assert.equal(#mixer.log.noteOffs, 1, "no voice expires while the timeline is frozen")
  player:resumePlayer(1)
  player:render(4000)
  Assert.equal(
    #mixer.log.updates,
    0,
    "resume does not resurrect the released voice: its handle is gone from the tracks"
  )
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "the frozen gate expires without re-releasing anything"
  )
  Assert.isFalse(player:isPlaying(), "the sequence ran out its frozen timeline after resume")
end

-- Pause and resume follow the NNS player-state guard: pausing an unknown
-- player or an already-paused player, and resuming an unknown or unpaused
-- player, are no-ops -- a fanfare without a BGM must never fault and a
-- double pause must not release twice.
function T.pause_and_resume_guards_are_no_ops()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  player:pausePlayer(3)
  player:resumePlayer(3)
  play(player, provider)
  player:render(200)
  player:pausePlayer(1)
  player:pausePlayer(1)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "the double pause releases exactly once"
  )
  player:resumePlayer(1)
  player:resumePlayer(1)
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "resume (once or twice) never releases again"
  )
  player:render(4000)
  Assert.isFalse(player:isPlaying())
end

-- A new sequence on a paused player replaces the released one: the paused
-- instance's handles were already freed, so the replacement releases
-- nothing extra and the fresh sequence starts cleanly.
function T.playing_on_a_paused_player_releases_and_replaces()
  local mixer = stubMixer()
  local player, provider = engine({
    [0] = seq({
      { op = "program", program = 0 },
      { op = "note", key = 60, velocity = 127, duration = 8 },
      { op = "end" },
    }),
  }, { mixer = mixer })
  play(player, provider)
  player:render(200)
  player:pausePlayer(1)
  player:play(provider:sequence(0), provider:bank(12))
  Assert.equal(#mixer.log.noteOns, 2, "the replacement starts its fresh sequence")
  Assert.deepEqual(
    mixer.log.noteOffs,
    { { handle = { channel = 3, generation = 0 }, releaseOverride = 127 } },
    "the pause release was the only release: the freed paused instance adds none"
  )
end

-- The per-player fader (the GameSound fade hook): setFader stores the
-- volume-domain level and the queued update delivers its dB-domain
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
  Assert.notNil(push, "the player queues a fader update to its active voice")
  Assert.equal(push.partial.fader, NnsSoundMath.decibelSquare(42), "the level reaches the mixer in the dB domain")
end

return { tests = T }
