-- Field save tests freeze stable capture, schema validation, stale terrain
-- recovery by height, ambiguous-layer rejection, and warp arrival suppression.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldSave = require("libs.engine.src.FieldSave")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function runtimeMap(hash, plates, warps)
  return {
    mapId = 60,
    coordinateOrigin = { x = 680, z = 390 },
    permissions = {
      containsLocal = function(_, x, z) return x >= 0 and x < 32 and z >= 0 and z < 32 end,
      isBlockedLocal = function() return false end,
    },
    terrain = TerrainSurface.new({ plates = plates }),
    terrainDependencyHash = hash,
    fieldData = { events = { warps = warps or {} } },
  }
end

local function flat(id, y)
  return { id = id, minX = 0, minZ = 0, maxX = 32, maxZ = 32,
    normal = { x = 0, y = 1, z = 0 }, distance = y,
    slopeClass = "flat", walkable = true }
end

local function record(overrides)
  local value = {
    schema = FieldSave.SCHEMA, versionId = "heartgold", mapId = 60,
    fieldX = 684, fieldZ = 393, worldY = 4, surfaceId = 11,
    terrainDependencyHash = "terrain-a", facing = "north",
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function restore(value, map)
  return FieldSave.restore(value, { load = function(_, mapId)
    Assert.equal(mapId, 60)
    return map
  end }, "heartgold")
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected structured error")
  Assert.equal(err.code, code)
end

function T.stable_state_round_trips_exactly()
  local map = runtimeMap("terrain-a", { flat(11, 4) })
  local session = {
    versionId = "heartgold", currentMap = map,
    player = { motion = "idle", fieldX = 684, fieldZ = 393,
      worldY = 4, surfaceId = 11, facing = "north" },
    transition = { phase = "idle" },
  }
  local saved = FieldSave.capture(session)
  Assert.deepEqual(saved, record())
  local result = assert(restore(saved, map))
  Assert.equal(result.surfaceId, 11)
  Assert.equal(result.worldY, 4)
end

function T.refuses_mid_step_and_mid_transition_capture()
  local walking = { player = { motion = "walking" }, transition = { phase = "idle" } }
  Assert.isFalse(FieldSave.canCapture(walking))
  local fading = { player = { motion = "idle" }, transition = { phase = "fade_out" } }
  Assert.isFalse(FieldSave.canCapture(fading))
  -- A half-open dialogue must never be captured (spec section 16.3).
  local halfOpen = { player = { motion = "idle" }, transition = { phase = "idle" },
    dialogue = { isModal = function() return true end } }
  Assert.isFalse(FieldSave.canCapture(halfOpen))
  local closed = { player = { motion = "idle" }, transition = { phase = "idle" },
    dialogue = { isModal = function() return false end } }
  Assert.isTrue(FieldSave.canCapture(closed))
end

function T.stale_surface_id_resamples_nearest_saved_height()
  local map = runtimeMap("terrain-b", { flat(2, 0), flat(7, 4.25) })
  local result = assert(restore(record(), map))
  Assert.equal(result.surfaceId, 7)
  Assert.equal(result.worldY, 4.25)
end

function T.stale_surface_rejects_ambiguous_height()
  local map = runtimeMap("terrain-b", { flat(2, 3), flat(7, 5) })
  throwsCode("FIELD_SAVE_SURFACE_AMBIGUOUS", function()
    local _, err = restore(record(), map)
    error(err)
  end)
end

function T.saved_warp_tile_initializes_arrival_suppression()
  local map = runtimeMap("terrain-a", { flat(11, 4) }, {
    { index = 0, x = 684, z = 393, destinationMapId = 61, destinationWarpId = 0 },
  })
  local result = assert(restore(record(), map))
  Assert.deepEqual(result.suppression, { mapId = 60, fieldX = 684, fieldZ = 393 })
end

function T.validates_schema_coordinates_facing_and_version()
  local map = runtimeMap("terrain-a", { flat(11, 4) })
  for _, case in ipairs({
    { "FIELD_SAVE_SCHEMA", { schema = "old" } },
    { "FIELD_SAVE_COORDINATES_INVALID", { fieldX = 1.5 } },
    { "FIELD_SAVE_HEIGHT_INVALID", { worldY = math.huge } },
    { "FIELD_SAVE_FACING_INVALID", { facing = "up" } },
    { "FIELD_SAVE_VERSION_MISMATCH", { versionId = "soulsilver" } },
  }) do
    throwsCode(case[1], function()
      local _, err = restore(record(case[2]), map)
      error(err)
    end)
  end
end

return T
