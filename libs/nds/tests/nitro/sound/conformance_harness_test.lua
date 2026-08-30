-- Conformance harness: interval phase ordering and trace stability.
-- Validates the optional semantic observer shared by SequencePlayer and VoiceMixer
-- and the AudioTrace recorder. Production behavior with no observer
-- remains unchanged; with an observer, each 192 Hz interval emits
-- before_sequence -> after_sequence -> after_channels and traces are
-- invariant to PCM render chunking.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioTrace = require("tests.support.AudioTrace")
local TestProvider = require("libs.nds.tests.nitro.sound.TestProvider")
local VoiceMixer = require("libs.nds.src.nitro.sound.VoiceMixer")
local SequencePlayer = require("libs.nds.src.nitro.sound.SequencePlayer")

local T = {}

local SAMPLE_RATE = 48000

local function seq(instructions, opts)
  opts = opts or {}
  return AudioFixture.sequence(opts.id or 0, opts.symbol or "SEQ_TEST", 12, opts.playerId or 1, {
    entry = 1,
    initialTrackMask = 0x0001,
    instructions = instructions,
  }, {
    id = opts.playerId or 1,
    initialVolume = 127,
    playerPriority = 64,
    channelPriority = 64,
  })
end

local function buildBundle(sequences)
  local keyA = AudioFixture.key(1)
  local bundle = AudioFixture.bundle()
  ---@cast bundle +{ samples: table<string, integer[]> }
  local indexSequences, indexPlayers, sequenceBySymbol = {}, {}, {}
  for id, sequence in pairs(sequences) do
    indexSequences[id] = { id = id, symbol = sequence.symbol, bankId = sequence.bankId, playerId = sequence.player.id }
    sequenceBySymbol[sequence.symbol] = id
    indexPlayers[sequence.player.id] = { id = sequence.player.id, maxSequences = 16, channelMask = 0xFFFF }
  end
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = { [12] = { id = 12, symbol = "BANK_TEST" } }
  bundle.index.sequenceBySymbol = sequenceBySymbol
  bundle.index.bankBySymbol = { BANK_TEST = 12 }
  bundle.sequences = sequences
  bundle.banks = { [12] = AudioFixture.bank(12, "BANK_TEST") }
  bundle.samples = {
    [keyA] = { 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000 },
  }
  bundle.sampleMetadata = {
    [keyA] = AudioFixture.sampleMetadata(keyA, { frames = 8, loop = { startFrame = 0, endFrame = 8 } }),
  }
  return bundle
end

local function engineWithTrace(program, opts)
  opts = opts or {}
  local trace = AudioTrace.new()
  local sequences = { [0] = seq(program) }
  local bundle = buildBundle(sequences)
  local provider = TestProvider.new(bundle)
  -- Observer is injected at construction and receives immutable snapshots.
  -- Use one shared observer for player and mixer via the trace recorder.
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE, observer = trace })
  local player = SequencePlayer.new({
    sampleRate = SAMPLE_RATE,
    mixer = mixer,
    provider = provider,
    observer = trace,
    rng = opts.rng,
  })
  return player, provider, trace, mixer
end

function T.interval_phase_order_is_before_sequence_then_after_sequence_then_after_channels()
  local player, provider, trace = engineWithTrace({
    { op = "note", key = 60, velocity = 100, duration = 4 },
    { op = "end" },
  })
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  -- At 48 kHz an interval is 250 frames. Render 3 intervals = 750 frames.
  player:render(750)

  Assert.isTrue(#trace.events > 0, "trace must expose the global callback stream")
  local positions = {}
  local function firstPosition(predicate)
    for index, entry in ipairs(trace.events) do
      if predicate(entry) then
        return index
      end
    end
    return nil
  end
  for index, entry in ipairs(trace.events) do
    local kind = entry.kind
    if positions[kind] == nil then
      positions[kind] = index
    end
  end
  Assert.notNil(positions.sound_interval, "interval callbacks must be recorded globally")
  Assert.notNil(positions.track_step, "track callbacks must be recorded globally")
  Assert.notNil(positions.note_event, "note callbacks must be recorded globally")
  Assert.notNil(positions.channel_state, "channel callbacks must be recorded globally")
  local beforeSequence = firstPosition(function(entry)
    return entry.kind == "sound_interval" and entry.event.ordinal == 0 and entry.event.phase == "before_sequence"
  end)
  local afterSequence = firstPosition(function(entry)
    return entry.kind == "sound_interval" and entry.event.ordinal == 0 and entry.event.phase == "after_sequence"
  end)
  local afterChannels = firstPosition(function(entry)
    return entry.kind == "sound_interval" and entry.event.ordinal == 0 and entry.event.phase == "after_channels"
  end)
  local sequenceWork = firstPosition(function(entry)
    return (entry.kind == "track_step" or entry.kind == "note_event") and entry.event.ordinal == 0
  end)
  local channelWork = firstPosition(function(entry)
    return entry.kind == "channel_state" and entry.event.ordinal == 0
  end)
  Assert.notNil(beforeSequence, "first interval must expose before_sequence globally")
  Assert.notNil(sequenceWork, "first interval must expose sequence work globally")
  Assert.notNil(afterSequence, "first interval must expose after_sequence globally")
  Assert.notNil(channelWork, "first interval must expose mixer work globally")
  Assert.notNil(afterChannels, "first interval must expose after_channels globally")
  Assert.isTrue(
    beforeSequence < sequenceWork
      and sequenceWork < afterSequence
      and afterSequence < channelWork
      and channelWork < afterChannels,
    "global stream must preserve interval, sequence, and mixer callback order"
  )

  -- The observer must emit three phases per 192 Hz interval in strict order.
  local intervals = trace.intervals
  Assert.isTrue(
    #intervals >= 9,
    "expected at least three intervals worth of phase events, got " .. #intervals .. " (" .. trace:summary() .. ")"
  )

  -- Group by ordinal and verify ordering inside each interval.
  local byOrdinal = {}
  for _, event in ipairs(intervals) do
    local list = byOrdinal[event.ordinal]
    if list == nil then
      list = {}
      byOrdinal[event.ordinal] = list
    end
    list[#list + 1] = event.phase
  end

  local ordinals = {}
  for ordinal in pairs(byOrdinal) do
    ordinals[#ordinals + 1] = ordinal
  end
  table.sort(ordinals)

  for _, ordinal in ipairs(ordinals) do
    local phases = byOrdinal[ordinal]
    Assert.deepEqual(
      phases,
      { "before_sequence", "after_sequence", "after_channels" },
      "interval " .. ordinal .. " phase order"
    )
  end

  -- Ordinals must be contiguous starting from 0 or 1 (allow either, but must increment by 1).
  for index = 2, #ordinals do
    Assert.equal(ordinals[index], ordinals[index - 1] + 1, "ordinal increments by one")
  end
end

function T.trace_is_stable_across_render_chunk_sizes()
  local program = {
    { op = "note", key = 60, velocity = 100, duration = 2 },
    { op = "wait", duration = 1 },
    { op = "note", key = 62, velocity = 100, duration = 1 },
    { op = "end" },
  }

  local function collect(chunks)
    local player, provider, trace = engineWithTrace(program)
    player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
    for _, frames in ipairs(chunks) do
      player:render(frames)
    end
    -- Also collect track and channel snapshots for stability.
    Assert.isTrue(#trace.events > 0, "global trace must be non-empty: " .. trace:summary())
    return trace
  end

  local a = collect({ 1000 })
  local b = collect({ 250, 250, 250, 250 })
  local c = collect({ 100, 200, 700 })

  Assert.isTrue(#a.intervals > 0, "trace must be non-empty when observer is enabled (chunk 1000): " .. a:summary())
  Assert.isTrue(#b.intervals > 0, "trace must be non-empty when observer is enabled (chunk 250*4): " .. b:summary())
  local ab = a:diagnostics(b)
  Assert.isTrue(ab == nil, "1000 vs 250*4 traces must be identical: " .. tostring(ab))

  local ac = a:diagnostics(c)
  Assert.isTrue(ac == nil, "1000 vs 100+200+700 traces must be identical: " .. tostring(ac))
end

function T.trace_determinism_is_identical_for_one_large_chunk_and_several_uneven_chunks()
  local program = {
    { op = "note", key = 60, velocity = 100, duration = 1 },
    { op = "jump", target = 1 },
  }

  local function collect(chunks)
    local player, provider, trace = engineWithTrace(program)
    player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
    for _, frames in ipairs(chunks) do
      player:render(frames)
    end
    Assert.isTrue(#trace.events > 0, "global trace must be non-empty: " .. trace:summary())
    return trace
  end

  local one = collect({ 2000 })
  local uneven = collect({ 700, 500, 300, 500 })
  local many = collect({ 250, 250, 250, 250, 250, 250, 250, 250 })

  Assert.isTrue(#one.intervals > 0, "determinism trace must be non-empty (one chunk): " .. one:summary())
  Assert.isTrue(#uneven.intervals > 0, "determinism trace must be non-empty (uneven): " .. uneven:summary())
  Assert.isTrue(#one.noteEvents >= 2, "determinism program emits notes in multiple intervals: " .. one:summary())
  for index, event in ipairs(one.noteEvents) do
    Assert.isTrue(type(event.ordinal) == "number", "note event " .. index .. " has a numeric interval ordinal")
  end
  Assert.isTrue(
    one.noteEvents[1].ordinal < one.noteEvents[2].ordinal,
    "note events retain occurrence order across intervals"
  )

  local d1 = one:diagnostics(uneven)
  Assert.isTrue(d1 == nil, "one large chunk vs uneven chunks must be identical: " .. tostring(d1))

  local d2 = one:diagnostics(many)
  Assert.isTrue(d2 == nil, "one large chunk vs eight small chunks must be identical: " .. tostring(d2))
end

function T.observer_absence_does_not_change_playback_behavior()
  -- With no observer, rendering must remain unchanged and not error.
  local bundle = buildBundle({ [0] = seq({ { op = "note", key = 60, velocity = 100, duration = 1 }, { op = "end" } }) })
  local provider = TestProvider.new(bundle)
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = SequencePlayer.new({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  player:play(player:createHandle(), provider:sequence(0), provider:bank(12))
  local pcm = player:render(500)
  Assert.isTrue(#pcm > 0, "rendering without observer must produce pcm")
  player:stop()
  Assert.isFalse(player:isPlaying(), "stop clears the short sequence without an observer")

  local partialObserver = {
    onSoundInterval = function() end,
  }
  local partialPlayer = SequencePlayer.new({
    sampleRate = SAMPLE_RATE,
    mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE }),
    provider = provider,
    observer = partialObserver,
  })
  partialPlayer:play(partialPlayer:createHandle(), provider:sequence(0), provider:bank(12))
  local partialPcm = partialPlayer:render(500)
  Assert.isTrue(#partialPcm > 0, "rendering with a partial observer must produce pcm")
end

function T.trace_recorder_treats_chronology_as_semantic_and_renders_mismatch_diagnostics()
  local a = AudioTrace.new()
  a:onSoundInterval({ ordinal = 0, phase = "before_sequence" })
  a:onTrackStep({ ordinal = 0, track = 0, op = "note" })

  local b = AudioTrace.new()
  b:onTrackStep({ ordinal = 0, track = 0, op = "note" })
  b:onSoundInterval({ ordinal = 0, phase = "before_sequence" })

  Assert.deepEqual(a.intervals, b.intervals, "category interval views remain identical")
  Assert.deepEqual(a.trackSteps, b.trackSteps, "category track views remain identical")
  local reordered = a:diagnostics(b)
  Assert.isTrue(
    reordered ~= nil
      and reordered:find("global event 1") ~= nil
      and reordered:find("sound_interval") ~= nil
      and reordered:find("track_step") ~= nil,
    "cross-kind reorder must identify the first global mismatch, got " .. tostring(reordered)
  )
  Assert.isFalse(a:equals(b), "global chronology must define whole-trace equality")
end

return { tests = T }
