-- P5 Nitro scheduler + mixer boundary acceptance tests
--
-- These tests verify the SequencePlayer/VoiceMixer boundary for exact Nitro
-- 192 Hz scheduling, tempoCounter model, RNG cadence, variable initialization,
-- exact dynamic operand casts, program/wait semantics, shared call/loop stack
-- depth 3, sequence-tick-owned note length/wait/non-auto-sweep progression,
-- attached vs detached release channel states, tie common-tail update, new-note
-- fader inheritance, and mixer external control step (spec §18.5-18.11).
--
-- These tests use a recording mixer fixture to capture:
-- - Exact frame index of each sequence tick and control step
-- - controlStep() call count and timing
-- - RNG draw sequence
-- - Voice allocation and release events
--
-- The contract: tests fail with clear, reproducible failures before P5
-- implementation. Do NOT implement production code; only acceptance tests.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")
local bit = require("bit")

local T = {
  metadata = {
    capabilities = {},
    tags = { "audio", "sequence", "scheduler", "mixer" },
  },
  tests = {},
}

local SAMPLE_RATE_32768 = 32768
local SAMPLE_RATE_48000 = 48000

local function voice(key, opts)
  opts = opts or {}
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = opts.pan or 0,
  }
end

-- Recording mixer fixture that captures all control-step calls and their
-- frame indices, plus sequence events (noteOn/Off) with timestamps.
-- This allows tests to verify exact 192 Hz boundary alignment without
-- depending on PCM output golden masters.
local RecordingMixer = {}
RecordingMixer.__index = RecordingMixer

function RecordingMixer.new()
  local self = setmetatable({}, RecordingMixer)
  self._frames = 0
  self._controlSteps = {} -- { frameIndex, callNumber }
  self._events = {} -- { type="noteOn"|"noteOff"|"updateVoice"|"advanceTrackTick", frameIndex, ... }
  self._voiceAlive = {} -- handle -> bool
  self._handles = {} -- generation counter
  self._nextGen = 1
  return self
end

function RecordingMixer:renderInto(out, frames)
  -- Pure PCM rendering; advance frame counter.
  -- Tests don't verify PCM, only event ordering.
  self._frames = self._frames + frames
  for i = 1, #out do
    out[i] = 0
  end
end

function RecordingMixer:controlStep()
  -- Record this control step at the current frame index.
  table.insert(self._controlSteps, {
    frameIndex = self._frames,
    callNumber = #self._controlSteps + 1,
  })
end

function RecordingMixer:noteOn(spec)
  local handle = { generation = self._nextGen, spec = spec }
  self._nextGen = self._nextGen + 1
  self._voiceAlive[handle] = true
  table.insert(self._events, {
    type = "noteOn",
    frameIndex = self._frames,
    handle = handle,
    spec = spec,
  })
  return handle
end

function RecordingMixer:noteOff(handle)
  if self._voiceAlive[handle] then
    table.insert(self._events, {
      type = "noteOff",
      frameIndex = self._frames,
      handle = handle,
    })
    self._voiceAlive[handle] = false
  end
end

function RecordingMixer:updateVoice(handle, partial)
  table.insert(self._events, {
    type = "updateVoice",
    frameIndex = self._frames,
    handle = handle,
    partial = partial,
  })
end

function RecordingMixer:advanceTrackTick(handle)
  table.insert(self._events, {
    type = "advanceTrackTick",
    frameIndex = self._frames,
    handle = handle,
  })
end

function RecordingMixer:isVoiceAlive(handle)
  return self._voiceAlive[handle] or false
end

function RecordingMixer:applyPending()
  -- No-op for recording fixture
end

-- Helper: assert that controlStep() was called at exact expected frame indices
local function assertControlStepFrames(mixer, sampleRate, expectedIntervals)
  -- expectedIntervals = { frame1, frame2, ... } — absolute frame indices where
  -- controlStep should be called
  local steps = mixer._controlSteps
  Assert.equal(#steps, #expectedIntervals,
    string.format("expected %d controlStep calls, got %d", #expectedIntervals, #steps))
  for i, expectedFrame in ipairs(expectedIntervals) do
    local step = steps[i]
    Assert.equal(step.frameIndex, expectedFrame,
      string.format("controlStep %d: expected frame %d, got %d", i, expectedFrame, step.frameIndex))
  end
end

-- Helper: calculate expected frame count for N sound intervals at given sample rate
-- At 32768 Hz: intervals are 170 or 171 frames alternating
-- At 48000 Hz: intervals are 250 frames each
local function expectedFramesForIntervals(sampleRate, intervalCount)
  if sampleRate == 32768 then
    -- 32768 Hz: alternating 170/171 frame intervals
    local frames = 0
    for i = 1, intervalCount do
      frames = frames + (i % 2 == 1 and 170 or 171)
    end
    return frames
  elseif sampleRate == 48000 then
    return intervalCount * 250
  end
  error("unsupported sample rate: " .. sampleRate)
end

-- Helper: first note should occur on first 192 Hz boundary AFTER play(), not in play()
T.tests["P5.1: first sequence tick occurs on first 192 Hz interval after play, not in play"] = function()
  local mixer = RecordingMixer.new()

  -- Build a simple bundle with one sequence and bank
  local key1 = AudioFixture.key(1)
  local noteSeq = AudioFixture.sequence(1, "SEQ_FIRST_NOTE", 1, 1, {
    entry = 1,
    instructions = {
      { op = "note", key = 60, velocity = 96, duration = 100 },
      { op = "wait", duration = 250 },
    },
  }, {
    id = 1,
    initialVolume = 127,
    playerPriority = 64,
  })

  local bank = AudioFixture.bank(1, "BANK_TEST", { key1 }, {
    [0] = { kind = "direct", voice = voice(key1) }
  })

  local bundle = AudioFixture.bundle()
  bundle.index.sequences[1] = {
    id = 1,
    symbol = "SEQ_FIRST_NOTE",
    bankId = 1,
    playerId = 1,
  }
  bundle.index.players[1] = {
    id = 1,
    maxSequences = 1,
    channelMask = 0xFFFF,
  }
  bundle.index.banks[1] = { id = 1, symbol = "BANK_TEST" }
  bundle.index.sequenceBySymbol = { SEQ_FIRST_NOTE = 1 }
  bundle.index.bankBySymbol = { BANK_TEST = 1 }
  bundle.sequences = { [1] = noteSeq }
  bundle.banks = { [1] = bank }
  bundle.samples = { [key1] = AudioFixture.pcm16le({ 1000, 2000, 3000 }) }
  bundle.sampleMetadata = { [key1] = AudioFixture.sampleMetadata(key1) }

  local provider = AudioAssetProvider.new(AudioFixture.readyCache(bundle))
  local player = SequencePlayer.new({
    sampleRate = SAMPLE_RATE_48000,
    mixer = mixer,
    provider = provider,
  })

  -- play() should NOT execute the entry program immediately
  player:play(noteSeq, bank)

  -- At this point, no noteOn should have occurred yet
  local notesBeforeRender = #mixer._events
  Assert.equal(notesBeforeRender, 0,
    "play() must not execute entry program immediately; expected 0 events, got " .. notesBeforeRender)

  -- Render up to but not including the first 192 Hz boundary
  player:render(249) -- just under 250 frames at 48kHz = 1 boundary

  -- Still no note
  Assert.equal(#mixer._events, 0,
    "rendering less than one 192 Hz interval should not trigger first tick")

  -- Render past the first boundary
  player:render(2) -- cross the 250-frame boundary

  -- Now we should have at least a noteOn from the entry program
  Assert.isTrue(#mixer._events > 0,
    "first 192 Hz boundary should trigger entry program execution and noteOn")

  local firstEvent = mixer._events[1]
  Assert.equal(firstEvent.type, "noteOn",
    "first event after 192 Hz boundary should be noteOn, got " .. firstEvent.type)
end



return T
