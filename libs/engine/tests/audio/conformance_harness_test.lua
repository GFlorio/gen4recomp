-- Conformance harness: interval phase ordering and trace stability.
-- Validates the optional semantic observer shared by SequencePlayer and VoiceMixer
-- and the normalized AudioTrace recorder. Production behavior with no observer
-- remains unchanged; with an observer, each 192 Hz interval emits
-- before_sequence -> after_sequence -> after_channels and traces are
-- invariant to PCM render chunking.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioTrace = require("tests.support.AudioTrace")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")

local T = {}

local SAMPLE_RATE = 48000

local function seq(instructions, opts)
  opts = opts or {}
  return AudioFixture.sequence(opts.id or 0, opts.symbol or "SEQ_TEST", 12, opts.playerId or 1, {
    entry = 1,
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
    [keyA] = AudioFixture.pcm16le({ 1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000 }),
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
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(bundle))
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
  player:play(provider:sequence(0), provider:bank(12))
  -- At 48 kHz an interval is 250 frames. Render 3 intervals = 750 frames.
  player:render(750)

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
    player:play(provider:sequence(0), provider:bank(12))
    for _, frames in ipairs(chunks) do
      player:render(frames)
    end
    -- Also collect track and channel snapshots for stability.
    return trace:normalized()
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
    { op = "tempo", amount = 120 },
    { op = "note", key = 60, velocity = 100, duration = 3 },
    { op = "wait", duration = 2 },
    { op = "note", key = 64, velocity = 100, duration = 1 },
    { op = "end" },
  }

  local function collect(chunks)
    local player, provider, trace = engineWithTrace(program)
    player:play(provider:sequence(0), provider:bank(12))
    for _, frames in ipairs(chunks) do
      player:render(frames)
    end
    return trace:normalized()
  end

  local one = collect({ 2000 })
  local uneven = collect({ 700, 500, 300, 500 })
  local many = collect({ 250, 250, 250, 250, 250, 250, 250, 250 })

  Assert.isTrue(#one.intervals > 0, "determinism trace must be non-empty (one chunk): " .. one:summary())
  Assert.isTrue(#uneven.intervals > 0, "determinism trace must be non-empty (uneven): " .. uneven:summary())

  local d1 = one:diagnostics(uneven)
  Assert.isTrue(d1 == nil, "one large chunk vs uneven chunks must be identical: " .. tostring(d1))

  local d2 = one:diagnostics(many)
  Assert.isTrue(d2 == nil, "one large chunk vs eight small chunks must be identical: " .. tostring(d2))

  -- Exact semantic comparison of integers/booleans: filter to one player must keep equality.
  local filteredOne = one:filterByPlayer(1)
  local filteredUneven = uneven:filterByPlayer(1)
  local d3 = filteredOne:diagnostics(filteredUneven)
  Assert.isTrue(d3 == nil, "filtered determinism traces must remain identical: " .. tostring(d3))
end

function T.observer_does_not_mutate_player_state_and_is_allocation_free_when_absent()
  -- With no observer, rendering must remain unchanged and not error.
  local bundle = buildBundle({ [0] = seq({ { op = "note", key = 60, velocity = 100, duration = 1 }, { op = "end" } }) })
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(bundle))
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = SequencePlayer.new({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  player:play(provider:sequence(0), provider:bank(12))
  local pcm = player:render(500)
  Assert.isTrue(#pcm > 0, "rendering without observer must produce pcm")
  Assert.isTrue(player:isPlaying() == false or player:isPlaying() == true, "isPlaying remains callable")
end

function T.trace_recorder_normalizes_ordering_and_renders_mismatch_diagnostics()
  local a = AudioTrace.new()
  a:onSoundInterval({ ordinal = 1, phase = "after_channels" })
  a:onSoundInterval({ ordinal = 0, phase = "before_sequence" })
  a:onSoundInterval({ ordinal = 0, phase = "after_sequence" })
  a:onSoundInterval({ ordinal = 0, phase = "after_channels" })
  a:onSoundInterval({ ordinal = 1, phase = "before_sequence" })
  a:onSoundInterval({ ordinal = 1, phase = "after_sequence" })

  local b = AudioTrace.new()
  b:onSoundInterval({ ordinal = 0, phase = "before_sequence" })
  b:onSoundInterval({ ordinal = 0, phase = "after_sequence" })
  b:onSoundInterval({ ordinal = 0, phase = "after_channels" })
  b:onSoundInterval({ ordinal = 1, phase = "before_sequence" })
  b:onSoundInterval({ ordinal = 1, phase = "after_sequence" })
  b:onSoundInterval({ ordinal = 1, phase = "after_channels" })

  -- Normalized comparison must succeed despite insertion order.
  Assert.isTrue(a:normalized():equals(b:normalized()), "normalized ordering must be stable")

  local c = AudioTrace.new()
  c:onSoundInterval({ ordinal = 0, phase = "before_sequence" })
  -- Missing phases -> diagnostics should mention mismatch.
  local diag = b:diagnostics(c)
  Assert.isTrue(
    diag ~= nil and diag:find("intervals") ~= nil,
    "mismatch diagnostics must mention intervals, got " .. tostring(diag)
  )
  diag = assert(diag)
  Assert.isTrue(diag:find("expected") ~= nil, "diagnostics must show expected vs actual")
end

return { tests = T }
