-- Compound beast movement trajectories (codes 105-112) normalized into
-- semantic trajectory segments. Expected values follow the pinned
-- pret/pokeheartgold movement setup functions (MapObjectMovementCmd105_Step0
-- and siblings in asm/unk_020632B0.s) and the step ordering in
-- asm/unk_data_020FDB44.s.

local Assert = require("tests.support.Assert")
local MovementDecoder = require("romdump.src.digest.script.MovementDecoder")

local T = {}

local EXPECTED = {
  [105] = {
    { deltaX = 0, surfaceBandDelta = 1, deltaZ = 5, direction = "south", ticks = 15 },
    { deltaX = 4, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 12 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = -5, direction = "north", ticks = 15 },
    { deltaX = -2, surfaceBandDelta = 0, deltaZ = -3, direction = "north", ticks = 9 },
    { deltaX = -4, surfaceBandDelta = 1, deltaZ = -4, direction = "west", ticks = 12 },
  },
  [106] = {
    { deltaX = 2, surfaceBandDelta = 1, deltaZ = 0, direction = "east", ticks = 6 },
    { deltaX = -1, surfaceBandDelta = 0, deltaZ = 5, direction = "south", ticks = 12 },
    { deltaX = -3, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 6 },
    { deltaX = -3, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 9 },
  },
  [107] = {
    { deltaX = 3, surfaceBandDelta = 1, deltaZ = -1, direction = "east", ticks = 6 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 4, direction = "south", ticks = 9 },
    { deltaX = -4, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 12 },
    { deltaX = 0, surfaceBandDelta = -1, deltaZ = -4, direction = "north", ticks = 6 },
    { deltaX = 1, surfaceBandDelta = 1, deltaZ = -3, direction = "north", ticks = 9 },
    { deltaX = 3, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 4, direction = "south", ticks = 12 },
  },
  [108] = {
    { deltaX = 2, surfaceBandDelta = 1, deltaZ = 5, direction = "south", ticks = 9 },
    { deltaX = 1, surfaceBandDelta = 0, deltaZ = 5, direction = "south", ticks = 12 },
  },
  [109] = {
    { deltaX = 3, surfaceBandDelta = 1, deltaZ = -1, direction = "east", ticks = 6 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 4, direction = "south", ticks = 9 },
    { deltaX = -4, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 12 },
    { deltaX = 0, surfaceBandDelta = -1, deltaZ = -4, direction = "north", ticks = 6 },
    { deltaX = 1, surfaceBandDelta = 1, deltaZ = -3, direction = "north", ticks = 9 },
    { deltaX = 3, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 5, direction = "south", ticks = 12 },
  },
  [110] = {
    { deltaX = 2, surfaceBandDelta = 1, deltaZ = 4, direction = "south", ticks = 9 },
    { deltaX = 1, surfaceBandDelta = 0, deltaZ = 5, direction = "south", ticks = 12 },
  },
  [111] = {
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 2, direction = "south", ticks = 6 },
    { deltaX = 2, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 6 },
    { deltaX = 3, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 2, direction = "south", ticks = 6 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = 2, direction = "south", ticks = 6 },
    { deltaX = -3, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 9 },
    { deltaX = -3, surfaceBandDelta = 0, deltaZ = 0, direction = "west", ticks = 9 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = -2, direction = "north", ticks = 6 },
    { deltaX = 0, surfaceBandDelta = 0, deltaZ = -3, direction = "north", ticks = 9 },
    { deltaX = 3, surfaceBandDelta = 0, deltaZ = 1, direction = "south", ticks = 9 },
  },
  [112] = {
    { deltaX = 4, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 4, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
    { deltaX = 4, surfaceBandDelta = 0, deltaZ = 0, direction = "east", ticks = 9 },
  },
}

local function checkSegment(actual, expected, context)
  Assert.keySet(actual, "action,deltaX,deltaZ,direction,surfaceBandDelta,ticks", context)
  Assert.equal(actual.action, "trajectory_segment", context)
  Assert.equal(actual.deltaX, expected.deltaX, context .. " deltaX")
  Assert.equal(actual.surfaceBandDelta, expected.surfaceBandDelta, context .. " surfaceBandDelta")
  Assert.equal(actual.deltaZ, expected.deltaZ, context .. " deltaZ")
  Assert.equal(actual.direction, expected.direction, context .. " direction")
  Assert.equal(actual.ticks, expected.ticks, context .. " ticks")
end

local function checkList(actual, expected, context)
  Assert.equal(#actual, #expected, context .. " segment count")
  for i, want in ipairs(expected) do
    checkSegment(actual[i], want, context .. " segment " .. i)
  end
end

-- Source movement 94/95 (west/east farther jumps) normalizes to the semantic
-- farther jump: direction, distance, speed, and count with no redundant
-- displacement field and no leaked source opcode.
-- Source: pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981,
-- asm/unk_02062108.s commands 94-95 are the three-cell west/east jumps.
function T.farther_jumps_normalize_to_semantic_distance_without_redundant_tiles()
  local cases = {
    { code = 94, direction = "west" },
    { code = 95, direction = "east" },
  }
  for _, case in ipairs(cases) do
    local decoded = assert(MovementDecoder.decode({ movementCode = case.code, count = 1 }))
    Assert.equal(#decoded, 1, "movement code " .. case.code .. " decodes to one action")
    Assert.keySet(decoded[1], "action,count,direction,distance,speed", "movement code " .. case.code .. " shape")
    Assert.deepEqual(decoded[1], {
      action = "jump",
      direction = case.direction,
      distance = "farther",
      speed = "fast",
      count = 1,
    }, "movement code " .. case.code .. " semantics")
  end
end

function T.compound_trajectories_match_source_segments()
  for code = 105, 112 do
    local decoded = assert(MovementDecoder.decode({ movementCode = code, count = 1 }))
    checkList(decoded, EXPECTED[code], "movement code " .. code)
  end
end

function T.trajectory_count_repeats_independent_segment_lists()
  local decoded = assert(MovementDecoder.decode({ movementCode = 105, count = 2 }))
  local expected = EXPECTED[105]
  Assert.equal(#decoded, 2 * #expected, "repeated segment count")
  for i = 1, #expected do
    checkSegment(decoded[i], expected[i], "first repetition segment " .. i)
    checkSegment(decoded[i + #expected], expected[i], "second repetition segment " .. i)
  end
  for i = 1, #expected do
    Assert.isTrue(decoded[i] ~= decoded[i + #expected], "repetition " .. i .. " shares a table")
  end
  decoded[1].direction = "north"
  Assert.equal(decoded[1 + #expected].direction, "south", "repetitions must be independent tables")
end

function T.invalid_trajectory_counts_fail()
  for _, count in ipairs({ 0, -1, 1.5 }) do
    Assert.throws(function()
      MovementDecoder.decode({ movementCode = 105, count = count })
    end, "count " .. tostring(count) .. " must fail")
  end
end

return { tests = T }
