-- Field-event resolver tests cover source-order coordinate matching and the
-- narrowly defined passive north-facing type-one background path.

local Assert = require("tests.support.Assert")
local FieldEventResolver = require("libs.engine.src.FieldEventResolver")
local FieldEventState = require("libs.engine.src.FieldEventState")

local T = {}

local function terrain()
  return { artifact = {}, plates = {}, plateById = {} }
end

local function map(coordinates, backgrounds)
  local value = {
    mapId = 60,
    mapSymbol = "test-map",
    coordinateOrigin = { x = 0, z = 0 },
    scene = {},
    fieldData = {
      events = {
        coordinates = coordinates or {},
        background = backgrounds or {},
      },
    },
    collision = {},
    terrain = terrain(),
    terrainDependencyHash = "test-terrain",
    fieldRegion = {},
    cameraType = 0,
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
  return value
end

local function player(x, z, facing)
  return {
    currentMap = map({}, {}),
    resolver = { terrain = terrain(), stepHeightLimit = 1.25 },
    occupancy = function()
      return nil
    end,
    fieldX = x,
    fieldZ = z,
    localX = x,
    localZ = z,
    worldX = x,
    worldY = 0,
    worldZ = z,
    previousWorldX = x,
    previousWorldY = 0,
    previousWorldZ = z,
    surfaceId = 0,
    facing = facing,
    motion = "idle",
    progressTicks = 0,
    durationTicks = 0,
    animationPaused = false,
    bufferedDirectionFresh = false,
  } --[[@as FieldPlayer]]
end

local function eventState(value)
  return FieldEventState.new({ vars = { [7] = value } })
end

function T.coordinate_matching_uses_source_order_and_half_open_bounds()
  local first = { index = 0, x = 4, z = 6, width = 2, height = 2, variableId = 7, requiredValue = 3, scriptId = 10 }
  local second = { index = 1, x = 5, z = 7, width = 2, height = 2, variableId = 7, requiredValue = 3, scriptId = 11 }
  local resolved = FieldEventResolver.resolveCoordinate(map({ first, second }), player(5, 7, "east"), eventState(3))
  resolved = assert(resolved)
  Assert.equal(resolved.coordinate.index, 0)
  Assert.equal(resolved.kind, "coordinate")
  Assert.equal(resolved.mapId, 60)
  Assert.equal(resolved.sourceFieldX, 5)
  Assert.equal(resolved.sourceFieldZ, 7)
  Assert.isNil(
    FieldEventResolver.resolveCoordinate(map({ first }), player(6, 6, "east"), eventState(3)),
    "the right edge is outside the rectangle"
  )
end

function T.coordinate_matching_skips_variable_mismatch_and_preserves_zero_script()
  local event = { index = 4, x = 4, z = 6, width = 1, height = 1, variableId = 7, requiredValue = 3, scriptId = 10 }
  Assert.isNil(FieldEventResolver.resolveCoordinate(map({ event }), player(4, 6, "north"), eventState(2)))
  event.scriptId = 0
  Assert.equal(
    assert(FieldEventResolver.resolveCoordinate(map({ event }), player(4, 6, "north"), eventState(3))).scriptId,
    0
  )
end

function T.passive_sign_uses_only_north_type_one_and_ignores_direction_raw()
  local typeOne = { index = 2, x = 4, z = 5, type = 1, directionRaw = 99, scriptId = 8 }
  local typeTwo = { index = 3, x = 4, z = 5, type = 2, directionRaw = 0, scriptId = 9 }
  local runtimeMap = map({}, { typeOne })
  local resolved = FieldEventResolver.resolvePassiveSign(runtimeMap, player(4, 6, "north"))
  resolved = assert(resolved)
  Assert.equal(resolved.kind, "background")
  Assert.equal(resolved.background.eventIndex, 2)
  Assert.isNil(FieldEventResolver.resolvePassiveSign(runtimeMap, player(4, 6, "south")))
  Assert.isNil(FieldEventResolver.resolvePassiveSign(map({}, { typeOne }), player(5, 6, "north")))
  Assert.isNil(FieldEventResolver.resolvePassiveSign(map({}, { typeTwo }), player(4, 6, "north")))
end

return { tests = T }
