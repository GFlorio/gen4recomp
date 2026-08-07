-- Public coverage for complete HGSS zone-event decoding, signed fields,
-- category combinations, exact consumption, and malformed source offsets.

local Assert = require("tests.support.Assert")
local ZoneEvents = require("libs.assets.src.ZoneEvents")
local Builder = require("tests.support.ZoneEventsBuilder")

local T = {}

local function fixture()
  return {
    backgroundEvents = {
      { scriptId = 10, type = 11, x = -12, z = 13, y = -14, direction = 3 },
    },
    objectEvents = {
      { objectEventId = 21, spriteId = 22, movement = 23, type = 24,
        eventFlag = 25, scriptId = 26, facingDirection = 0,
        param0 = 27, param1 = 28, param2 = 29, xRange = -2, yRange = 3,
        x = 30, z = 31, y = -32 },
    },
    warps = {
      { x = 684, z = 393, destinationMapId = 61, destinationWarpId = 4, y = 7 },
    },
    coordinateEvents = {
      { scriptId = 41, x = -42, z = 43, width = 44, height = 45, y = 46,
        requiredValue = 47, variableId = 48 },
    },
  }
end

function T.decodes_every_field_and_preserves_zero_based_indexes()
  local bytes = Builder.build(fixture())
  local result = assert(ZoneEvents.decode(bytes,
    { mapId = 60, eventMemberId = 57, source = "fixture" }))
  Assert.equal(result.schema, "hgss-zone-events-v1")
  Assert.equal(result.mapId, 60)
  Assert.equal(result.eventMemberId, 57)
  Assert.equal(result.byteLength, #bytes)
  Assert.equal(result.consumedBytes, #bytes)
  Assert.isNil(result.trailingBytes)

  Assert.deepEqual(result.backgroundEvents[1], {
    index = 0, scriptId = 10, type = 11, x = -12, z = 13, y = -14,
    directionRaw = 3, direction = "east",
  })
  Assert.deepEqual(result.objectEvents[1], {
    index = 0, objectEventId = 21, spriteId = 22, movement = 23, type = 24,
    eventFlag = 25, scriptId = 26, facingDirectionRaw = 0,
    facingDirection = "north", param0 = 27, param1 = 28, param2 = 29,
    xRange = -2, yRange = 3, x = 30, z = 31, y = -32,
  })
  Assert.deepEqual(result.warps[1], {
    index = 0, x = 684, z = 393, destinationMapId = 61,
    destinationWarpId = 4, y = 7,
  })
  Assert.deepEqual(result.coordinateEvents[1], {
    index = 0, scriptId = 41, x = -42, z = 43, width = 44, height = 45,
    y = 46, requiredValue = 47, variableId = 48,
  })
end

function T.supports_all_zero_counts()
  local bytes = Builder.build()
  local result = assert(ZoneEvents.decode(bytes))
  Assert.equal(#result.backgroundEvents, 0)
  Assert.equal(#result.objectEvents, 0)
  Assert.equal(#result.warps, 0)
  Assert.equal(#result.coordinateEvents, 0)
  Assert.equal(result.consumedBytes, 16)
end

function T.reports_the_first_truncated_record_source_offset()
  local bytes = Builder.build(fixture())
  local result, err = ZoneEvents.decode(bytes:sub(1, 22))
  Assert.isNil(result)
  Assert.equal(assert(err).code, "ZONE_EVENTS_TRUNCATED")
  Assert.equal(assert(err).context.category, "backgroundEvents")
  Assert.equal(assert(err).context.recordIndex, 0)
  Assert.equal(assert(err).context.sourceOffset, 4)
end

function T.rejects_or_optionally_preserves_trailing_bytes()
  local bytes = Builder.build() .. "tail"
  local result, err = ZoneEvents.decode(bytes)
  Assert.isNil(result)
  Assert.equal(assert(err).code, "ZONE_EVENTS_TRAILING_BYTES")
  Assert.equal(assert(err).context.sourceOffset, 16)
  result = assert(ZoneEvents.decode(bytes, { allowTrailingBytes = true }))
  Assert.equal(result.consumedBytes, 16)
  Assert.equal(result.trailingBytes, "tail")
end

return T
