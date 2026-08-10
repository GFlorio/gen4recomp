-- Field save tests freeze stable capture, schema validation, event/avatar
-- persistence, stale terrain recovery by height, ambiguous-layer rejection,
-- and warp arrival suppression.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldSave = require("libs.engine.src.FieldSave")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function runtimeMap(hash, plates, warps)
  return {
    mapId = 60,
    coordinateOrigin = { x = 680, z = 390 },
    permissions = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({ plates = plates }),
    terrainDependencyHash = hash,
    fieldData = { events = { warps = warps or {} } },
  }
end

local function flat(id, y)
  return {
    id = id,
    minX = 0,
    minZ = 0,
    maxX = 32,
    maxZ = 32,
    normal = { x = 0, y = 1, z = 0 },
    distance = y,
    slopeClass = "flat",
    walkable = true,
  }
end

local function record(overrides)
  local value = {
    schema = FieldSave.SCHEMA,
    versionId = "heartgold",
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 4,
    surfaceId = 11,
    terrainDependencyHash = "terrain-a",
    facing = "north",
    avatar = "hero",
    scenario = "pre-script-demo-v1",
    world = { flags = {}, variables = {}, objects = {}, rng = {} },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function session(map)
  return {
    versionId = "heartgold",
    currentMap = map,
    player = { motion = "idle", fieldX = 684, fieldZ = 393, worldY = 4, surfaceId = 11, facing = "north" },
    transition = { phase = "idle" },
  }
end

local function capture(map, opts)
  opts = opts or {}
  return FieldSave.capture(session(map), {
    avatarId = opts.avatarId or "hero",
    world = opts.world,
    scenario = opts.scenario or "pre-script-demo-v1",
  })
end

local function restore(value, map)
  return FieldSave.restore(value, {
    load = function(_, mapId)
      Assert.equal(mapId, 60)
      return map
    end,
  }, "heartgold")
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected structured error")
  Assert.equal(err.code, code)
end

function T.stable_state_round_trips_exactly()
  local map = runtimeMap("terrain-a", { flat(11, 4) })
  local saved = capture(map)
  Assert.deepEqual(saved, record())
  local result = assert(restore(saved, map))
  Assert.equal(result.surfaceId, 11)
  Assert.equal(result.worldY, 4)
  Assert.equal(result.avatar, "hero")
  Assert.equal(result.scenario, "pre-script-demo-v1")
  Assert.deepEqual(result.world, { flags = {}, variables = {}, objects = {}, rng = {} })
end

function T.event_flags_and_vars_round_trip()
  local map = runtimeMap("terrain-a", { flat(11, 4) })
  local state = FieldEventState.new()
  state:setFlag(413)
  state:setFlag(744)
  state:setVar(0x4020, 97)
  local serialized = state:serialize()
  local world = { flags = serialized.flags, variables = serialized.vars, objects = {}, rng = {} }
  local saved = capture(map, { world = world, avatarId = "heroine" })
  Assert.deepEqual(saved.world, world)
  local result = assert(restore(saved, map))
  Assert.equal(result.avatar, "heroine")
  Assert.deepEqual(result.world, saved.world)
  local revived = FieldEventState.new({
    flags = result.world.flags,
    vars = result.world.variables,
  })
  Assert.isTrue(revived:isFlagSet(413))
  Assert.isTrue(revived:isFlagSet(744))
  Assert.isFalse(revived:isFlagSet(401))
  Assert.equal(revived:getVar(0x4020), 97)
  Assert.equal(revived:getVar(0x4021), 0, "absent variables default to zero")
end

function T.refuses_mid_step_and_mid_transition_capture()
  local walking = { player = { motion = "walking" }, transition = { phase = "idle" } }
  Assert.isFalse(FieldSave.canCapture(walking))
  local fading = { player = { motion = "idle" }, transition = { phase = "fade_out" } }
  Assert.isFalse(FieldSave.canCapture(fading))
  -- A half-open dialogue must never be captured.
  local halfOpen = {
    player = { motion = "idle" },
    transition = { phase = "idle" },
    dialogue = {
      isModal = function()
        return true
      end,
    },
  }
  Assert.isFalse(FieldSave.canCapture(halfOpen))
  local closed = {
    player = { motion = "idle" },
    transition = { phase = "idle" },
    dialogue = {
      isModal = function()
        return false
      end,
    },
  }
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

function T.unknown_schema_is_rejected_as_newer()
  throwsCode("FIELD_SAVE_SCHEMA_NEWER", function()
    local _, err = FieldSave.validate({ schema = "old" })
    error(err)
  end)
  throwsCode("FIELD_SAVE_SCHEMA_NEWER", function()
    local _, err = FieldSave.validate(record({ schema = "g4-field-save-v9" }))
    error(err)
  end)
  -- The schema is the only one that exists: any other version is rejected
  -- even when the rest of the record is complete.
  throwsCode("FIELD_SAVE_SCHEMA_NEWER", function()
    local prior = record()
    prior.schema = "g4-field-save-v0"
    local _, err = FieldSave.validate(prior)
    error(err)
  end)
end

function T.validates_schema_coordinates_facing_and_version()
  local map = runtimeMap("terrain-a", { flat(11, 4) })
  for _, case in ipairs({
    { "FIELD_SAVE_SCHEMA_NEWER", { schema = "old" } },
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

function T.invalid_avatar_identifiers_are_rejected()
  throwsCode("FIELD_SAVE_AVATAR_INVALID", function()
    local _, err = FieldSave.validate(record({ avatar = "" }))
    error(err)
  end)
  throwsCode("FIELD_SAVE_AVATAR_INVALID", function()
    local missing = record()
    missing.avatar = nil
    local _, err = FieldSave.validate(missing)
    error(err)
  end)
  -- With the compiled avatar set provided, an unbuilt graphic is rejected.
  throwsCode("FIELD_SAVE_AVATAR_INVALID", function()
    local _, err = FieldSave.validate(record({ avatar = "rival" }), { avatars = { hero = true, heroine = true } })
    error(err)
  end)
  -- The compiled set accepts the built player graphics.
  Assert.notNil(FieldSave.validate(record({ avatar = "heroine" }), { avatars = { hero = true, heroine = true } }))
end

function T.invalid_scenario_ids_are_rejected()
  throwsCode("FIELD_SAVE_SCENARIO_INVALID", function()
    local _, err = FieldSave.validate(record({ scenario = 5 }))
    error(err)
  end)
  throwsCode("FIELD_SAVE_SCENARIO_INVALID", function()
    local _, err = FieldSave.validate(record({ scenario = "" }))
    error(err)
  end)
  Assert.notNil(FieldSave.validate(record({ scenario = nil })))
end

function T.invalid_world_is_rejected_as_save_error()
  -- The world bucket is validated through the caller's worldValidate hook;
  -- a non-table world is a schema error regardless.
  throwsCode("FIELD_SAVE_WORLD_INVALID", function()
    local _, err = FieldSave.validate(record({ world = "not-a-table" }))
    error(err)
  end)
  for _, world in ipairs({
    { flags = { [-1] = true }, variables = {} },
    { flags = { [70000] = true }, variables = {} },
    { flags = { [5] = true }, variables = { [0x4020] = -1 } },
    { flags = { [5] = "yes" }, variables = {} },
  }) do
    throwsCode("FIELD_SAVE_WORLD_INVALID", function()
      local _, err = FieldSave.validate(record({ world = world }), {
        worldValidate = function(value)
          return pcall(FieldEventState.new, {
            flags = value.flags,
            vars = value.variables,
          }) and nil or Errors.new("WORLD_EVENT_STATE_INVALID", "bad event state", {})
        end,
      })
      error(err)
    end)
  end
end

function T.event_state_over_the_safety_limit_is_rejected()
  local flags = {}
  for id = 1, FieldEventState.MAX_ENTRIES + 1 do
    flags[id] = true
  end
  throwsCode("FIELD_SAVE_WORLD_INVALID", function()
    local _, err = FieldSave.validate(
      record({
        world = { flags = flags, variables = {}, objects = {}, rng = {} },
      }),
      {
        worldValidate = function(value)
          return pcall(FieldEventState.new, {
            flags = value.flags,
            vars = value.variables,
          }) and nil or Errors.new("WORLD_EVENT_STATE_INVALID", "bad event state", {})
        end,
      }
    )
    error(err)
  end)
end

return T
