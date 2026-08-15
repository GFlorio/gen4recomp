-- Field save tests freeze stable capture, schema validation, event/avatar
-- persistence, stale terrain recovery by height, ambiguous-layer rejection,
-- and warp arrival suppression.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldSave = require("libs.engine.src.FieldSave")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function runtimeMap(hash, plates, warps)
  return {
    mapId = 60,
    coordinateOrigin = { x = 680, z = 390 },
    collision = {
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

local function world(overrides)
  local value = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

-- The validation context mirrors the runtime injection: the generated font
-- charmap (A-Z resolvable) and an imported dialogue frame-index set.
local function playerDataContext()
  return {
    charmap = {
      G = 305,
      O = 313,
      L = 310,
      D = 302,
      H = 306,
      I = 307,
      K = 309,
      A = 299,
      R = 316,
    },
    frameIndexes = { [0] = true, [1] = true },
  }
end

local function playerData(overrides)
  local value = {
    profile = { name = "GOLD", gender = 0, trainerId = 0 },
    options = { textFrame = 0, textSpeed = "mid" },
  }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
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
    world = world(),
    scripts = {},
    auxiliaryUi = { requested = "shown", state = "shown" },
    playerData = playerData(),
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
    world = opts.world or world(),
    scenario = opts.scenario or "pre-script-demo-v1",
    scriptsBucket = opts.scriptsBucket or {},
    auxiliaryUi = opts.auxiliaryUi or { requested = "shown", state = "shown" },
    playerData = opts.playerData or playerData(),
  })
end

local function restore(value, map)
  return FieldSave.restore(value, {
    load = function(_, mapId)
      Assert.equal(mapId, 60)
      return map
    end,
  }, "heartgold", { playerDataContext = playerDataContext() })
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
  Assert.deepEqual(result.world, { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } })
end

function T.auxiliary_ui_state_round_trips_with_the_field_save()
  local map = runtimeMap("terrain-a", { flat(11, 4) })
  local auxiliaryUi = { requested = "hidden", state = "hiding" }

  local saved = capture(map, { auxiliaryUi = auxiliaryUi })
  local restored = assert(restore(saved, map))

  Assert.deepEqual(saved.auxiliaryUi, auxiliaryUi)
  Assert.deepEqual(restored.auxiliaryUi, auxiliaryUi)
end

-- The player-data bucket is required and round-trips exactly: a resumed
-- session must restore the saved profile/options record, not the initial
-- manifest.
function T.player_data_bucket_round_trips_exactly()
  local map = runtimeMap("terrain-a", { flat(11, 4) })
  local modified = playerData({
    profile = { name = "HIKARI", gender = 1, trainerId = 65535 },
    options = { textFrame = 1, textSpeed = "slow" },
  })

  local saved = capture(map, { playerData = modified })
  local restored = assert(restore(saved, map))

  Assert.deepEqual(saved.playerData, modified)
  Assert.deepEqual(restored.playerData, modified)
end

-- The current schema requires the player-data bucket: an old or hand-edited
-- record missing it is rejected with the structured player-data error, never
-- defaulted or upgraded.
function T.missing_player_data_bucket_is_rejected()
  throwsCode("FIELD_SAVE_PLAYER_DATA_INVALID", function()
    local missing = record()
    missing.playerData = nil
    local _, err = FieldSave.validate(missing)
    error(err)
  end)
end

-- The player-data validation context is a required composition contract:
-- without the generated charmap and frame-index set no call path may accept
-- player data, so a missing context is a loud programming fault, never a
-- silent validation downgrade.
function T.missing_player_data_context_is_a_composition_fault()
  Assert.throws(function()
    FieldSave.validate(record())
  end)
  Assert.throws(function()
    FieldSave.restore(record(), {
      load = function() end,
    }, "heartgold")
  end)
end

-- With the injected validation context (the generated font charmap and the
-- imported frame-index set), an invalid player-data record is rejected at the
-- save boundary as a whole, and the cause names the model's own code.
function T.invalid_player_data_is_rejected_at_the_schema_boundary()
  local context = playerDataContext()
  throwsCode("FIELD_SAVE_PLAYER_DATA_INVALID", function()
    local _, err = FieldSave.validate(
      record({ playerData = playerData({ profile = { name = "GOLDGOLD", gender = 0, trainerId = 0 } }) }),
      { playerDataContext = context }
    )
    error(err)
  end)
  throwsCode("FIELD_SAVE_PLAYER_DATA_INVALID", function()
    local _, err = FieldSave.validate(
      record({ playerData = playerData({ options = { textFrame = 9, textSpeed = "mid" } }) }),
      { playerDataContext = context }
    )
    error(err)
  end)
  -- A valid record passes with the same context.
  Assert.notNil(FieldSave.validate(record(), { playerDataContext = context }))
end

function T.invalid_auxiliary_ui_state_is_rejected()
  throwsCode("FIELD_SAVE_AUXILIARY_UI_INVALID", function()
    local missing = record()
    missing.auxiliaryUi = nil
    local _, err = FieldSave.validate(missing)
    error(err)
  end)
  for _, auxiliaryUi in ipairs({
    { requested = "visible", state = "shown" },
    { requested = "shown", state = "unknown" },
    { requested = "shown", state = "hidden" },
  }) do
    throwsCode("FIELD_SAVE_AUXILIARY_UI_INVALID", function()
      local _, err = FieldSave.validate(record({ auxiliaryUi = auxiliaryUi }))
      error(err)
    end)
  end
end

function T.event_flags_and_vars_round_trip()
  local map = runtimeMap("terrain-a", { flat(11, 4) })
  local state = FieldEventState.new()
  state:setFlag(413)
  state:setFlag(744)
  state:setVar(0x4020, 97)
  local serialized = state:serialize()
  local world = { flags = serialized.flags, variables = serialized.vars, objects = {}, rng = { state = 1, calls = 0 } }
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
  -- A presented signpost window is transient state: capture stays closed
  -- until the signpost hides.
  local signpostOpen = {
    player = { motion = "idle" },
    transition = { phase = "idle" },
    signpost = {
      isModal = function()
        return true
      end,
    },
  }
  Assert.isFalse(FieldSave.canCapture(signpostOpen))
  local signpostClosed = {
    player = { motion = "idle" },
    transition = { phase = "idle" },
    signpost = {
      isModal = function()
        return false
      end,
    },
  }
  Assert.isTrue(FieldSave.canCapture(signpostClosed))
  -- The application host (Start Menu, application fade, or a child
  -- application) is transient modal state: capture stays closed in every
  -- active phase and opens again at the settled field boundary.
  local appHost = {
    isActive = function()
      return true
    end,
  }
  local applicationOpen = {
    player = { motion = "idle" },
    transition = { phase = "idle" },
    applicationHost = appHost,
  }
  Assert.isFalse(FieldSave.canCapture(applicationOpen))
  local applicationClosed = {
    player = { motion = "idle" },
    transition = { phase = "idle" },
    applicationHost = {
      isActive = function()
        return false
      end,
    },
  }
  Assert.isTrue(FieldSave.canCapture(applicationClosed))
  -- A session without the host surface (older fixtures) still captures.
  local hostless = { player = { motion = "idle" }, transition = { phase = "idle" } } ---@type any
  Assert.isTrue(FieldSave.canCapture(hostless))
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

function T.any_unknown_schema_is_rejected_as_unsupported()
  -- The schema is the only one that exists: older, newer, and arbitrary
  -- identifiers are all rejected with the same unsupported-schema error even
  -- when the rest of the record is complete.
  for _, schema in ipairs({ "old", "g4-field-save-v9", "g4-field-save-v2", "g4-field-save-v1", "g4-field-save-v0" }) do
    throwsCode("FIELD_SAVE_SCHEMA_UNSUPPORTED", function()
      local _, err = FieldSave.validate(record({ schema = schema }))
      error(err)
    end)
  end
end

function T.missing_required_world_and_scripts_buckets_are_rejected()
  throwsCode("FIELD_SAVE_WORLD_INVALID", function()
    local missing = record()
    missing.world = nil
    local _, err = FieldSave.validate(missing)
    error(err)
  end)
  throwsCode("FIELD_SAVE_SCRIPTS_INVALID", function()
    local missing = record()
    missing.scripts = nil
    local _, err = FieldSave.validate(missing)
    error(err)
  end)
  throwsCode("FIELD_SAVE_WORLD_INVALID", function()
    local _, err = FieldSave.validate(record({ world = "not-a-table" }))
    error(err)
  end)
end

function T.validates_schema_coordinates_facing_and_version()
  local map = runtimeMap("terrain-a", { flat(11, 4) })
  for _, case in ipairs({
    { "FIELD_SAVE_SCHEMA_UNSUPPORTED", { schema = "old" } },
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
  Assert.notNil(FieldSave.validate(record({ avatar = "heroine" }), {
    avatars = { hero = true, heroine = true },
    playerDataContext = playerDataContext(),
  }))
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
  -- The current runtime capture always emits the scenario id: absence is
  -- invalid, not a defaulting case.
  throwsCode("FIELD_SAVE_SCENARIO_INVALID", function()
    local missing = record()
    missing.scenario = nil
    local _, err = FieldSave.validate(missing)
    error(err)
  end)
end

-- The schema boundary itself owns deep world validation through the
-- authoritative event-state and rng validators: no caller hook can skip it.
function T.valid_world_passes_deep_validation()
  local value = world({
    flags = { [413] = true },
    variables = { [0x4020] = 97 },
    rng = { state = 42, calls = 3 },
  })
  local valid = assert(FieldSave.validate(record({ world = value }), { playerDataContext = playerDataContext() }))
  Assert.deepEqual(valid.world, value)
end

function T.invalid_world_data_is_rejected_at_the_schema_boundary()
  local cases = {
    { flags = { [-1] = true }, variables = {} },
    { flags = { [70000] = true }, variables = {} },
    { flags = { [5] = true }, variables = { [0x4020] = -1 } },
    { flags = { [5] = "yes" }, variables = {} },
    { flags = {}, variables = { [0x4020] = 1.5 } },
    { objects = "none" },
    { rng = {} },
    { rng = { state = 0, calls = 0 } },
    { rng = { state = 1, calls = -1 } },
  }
  for _, value in ipairs(cases) do
    throwsCode("FIELD_SAVE_WORLD_INVALID", function()
      local _, err = FieldSave.validate(record({ world = world(value) }))
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
    local _, err = FieldSave.validate(record({ world = world({ flags = flags }) }))
    error(err)
  end)
end

return { tests = T }
