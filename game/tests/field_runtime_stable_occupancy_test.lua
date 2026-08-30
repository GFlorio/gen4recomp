-- The composed player/runtime occupancy boundary must preserve physical source
-- identity while destination probing remains read-only and presentation-free.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldRuntime = require("game.src.game.FieldRuntime")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

---@class StableOccupancyAssets: FieldActorAssets
---@field acquired integer

local function terrain(plates)
  return TerrainSurface.new({ plates = plates })
end

local function plate(id, distance, cellKey, sourceSurfaceId)
  return {
    id = id,
    minX = 0,
    minZ = 0,
    maxX = 32,
    maxZ = 32,
    normal = { x = 0, y = 1, z = 0 },
    distance = distance,
    slopeClass = "flat",
    cellKey = cellKey,
    sourceSurfaceId = sourceSurfaceId,
  }
end

local function object(objectEventId, x, z, y, spriteId)
  return {
    index = objectEventId,
    objectEventId = objectEventId,
    spriteId = spriteId or 99,
    movement = 0,
    type = 0,
    eventFlag = 0,
    scriptId = 1,
    facingDirection = "south",
    facingDirectionRaw = 1,
    param0 = 0,
    param1 = 0,
    param2 = 0,
    xRange = 0,
    yRange = 0,
    x = x,
    z = z,
    y = y,
  }
end

---@return StableOccupancyAssets
local function assets()
  local provider = {
    acquired = 0,
    knows = function()
      return true
    end,
    acquire = function(self, _)
      self.acquired = self.acquired + 1
      return { spriteId = 99, visual = {}, references = 1 }
    end,
    release = function(self, _)
      self.acquired = self.acquired - 1
    end,
  } ---@type StableOccupancyAssets
  return provider
end

function T.off_window_solid_actor_blocks_without_publishing_destination_state()
  local destination = {
    mapId = 62,
    mapSection = "test-section",
    mapSymbol = "destination",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, fieldX, fieldZ)
        return fieldX >= 0 and fieldX < 32 and fieldZ >= 0 and fieldZ < 32
      end,
    },
    terrain = terrain({ plate(0, 0, "1:0", 30), plate(1, 4, "1:0", 31) }),
    fieldData = {
      events = {
        objects = {
          object(0, 1, 0, 0),
          object(1, 1, 0, 4 * 16, 34),
        },
      },
    },
    scene = {},
    cameraType = 4,
    release = function() end,
    updateAnimated = function() end,
  } ---@as RuntimeFieldMap
  local source = {
    mapId = 61,
    mapSection = "test-section",
    mapSymbol = "source",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, fieldX, fieldZ)
        return fieldX >= 0 and fieldX < 32 and fieldZ >= 0 and fieldZ < 32
      end,
    },
    terrain = terrain({ plate(0, 0, "0:0", 12) }),
    fieldData = { events = { objects = {} } },
    scene = {},
    cameraType = 4,
    release = function() end,
    updateAnimated = function() end,
  } ---@as RuntimeFieldMap
  local coverage = {}
  function coverage:containsGlobal()
    return false
  end
  function coverage:mapHeaderAt(fieldX, fieldZ)
    Assert.equal(fieldX, 1)
    Assert.equal(fieldZ, 0)
    return destination.mapId
  end
  source.coverage = coverage
  function source:probePhysicalCell(fieldX, fieldZ)
    Assert.equal(fieldX, 1)
    Assert.equal(fieldZ, 0)
    return {
      collision = { blocked = false },
      cellKey = "1:0",
      sourceSurfaceId = 30,
      worldY = 0,
    }
  end

  local eventState = FieldEventState.new()
  local assetProvider = assets()
  local actors = FieldActorManager.new({
    assets = assetProvider,
    policy = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } },
  })
  ---@cast source RuntimeFieldMap
  actors:enterMap(source, eventState)

  local residency = {}
  function residency:mapForId(mapId)
    Assert.equal(mapId, destination.mapId)
    return nil
  end

  local player
  local runtime = setmetatable({
    runtimeMap = source,
    actors = actors,
    eventState = eventState,
    player = nil,
    residency = residency,
    zoneController = {},
  }, FieldRuntime)
  function residency:mapForPreflight(mapId)
    Assert.equal(mapId, destination.mapId)
    return destination
  end
  player = FieldPlayer.new({
    currentMap = source,
    fieldX = 0,
    fieldZ = 0,
    surfaceId = 0,
    facing = "east",
    occupancy = function(candidate)
      return runtime:_playerOccupantAt(candidate)
    end,
  })
  runtime.player = player

  local admitted = player:tryStep("east")
  Assert.equal(player.fieldX, 0)
  Assert.equal(player.fieldZ, 0)
  Assert.isNil(actors.maps[destination.mapId], "read-only probing must not publish the destination map")
  Assert.equal(assetProvider.acquired, 0, "read-only probing must not acquire actor visuals")
  Assert.isFalse(admitted, "a matching off-window source surface must block movement")
  Assert.equal(player.motion, "idle")
  actors:dispose()
end

-- Being logically resident does not make a neighboring map's objects live
-- and mutable: the only active actor entry is the source map's, and a
-- resident-but-inactive destination is represented purely through its
-- source events (read-only), matching the exact identity a construction-time
-- actor would have -- including a variable sprite resolved from the
-- supplied event state.
function T.resident_but_inactive_neighbor_blocks_and_interacts_through_read_only_probing()
  local eventState = FieldEventState.new({ vars = { [0x4020] = 34 } })
  local destinationEvent = object(0, 2, 0, 0, 101)
  destinationEvent.scriptId = 777
  local destination = {
    mapId = 62,
    mapSection = "test-section",
    mapSymbol = "destination",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, fieldX, fieldZ)
        return fieldX >= 0 and fieldX < 32 and fieldZ >= 0 and fieldZ < 32
      end,
    },
    terrain = terrain({ plate(0, 0, "1:0", 30) }),
    fieldData = { events = { objects = { destinationEvent }, background = {} } },
    scene = {},
    cameraType = 4,
    coverage = {
      containsGlobal = function()
        return true
      end,
    },
    release = function() end,
    updateAnimated = function() end,
  } ---@as RuntimeFieldMap
  local source = {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { objects = {} } },
    coverage = {},
  } ---@as RuntimeFieldMap
  function source.coverage:mapHeaderAt(fieldX, fieldZ)
    Assert.equal(fieldX == 1 or fieldX == 2, true)
    Assert.equal(fieldZ, 0)
    return destination.mapId
  end

  local assetProvider = assets()
  local actors = FieldActorManager.new({
    assets = assetProvider,
    policy = { variableSprites = { first = 101, last = 117, variableBase = 0x4020 } },
  })
  -- The active actor world is the source map only; the resident destination
  -- never receives a live entry.
  actors:enterMap(source --[[@as RuntimeFieldMap]], eventState)

  local residency = {}
  function residency:mapForId(mapId)
    Assert.equal(mapId, destination.mapId)
    return destination
  end
  local runtime = setmetatable({
    runtimeMap = source,
    actors = actors,
    eventState = eventState,
    residency = residency,
    zoneController = {
      mapForPreflight = function()
        error("a logically resident destination must never be preflighted", 0)
      end,
    },
  }, FieldRuntime)

  Assert.isNil(runtime:_playerOccupantAt({ fieldX = 1, fieldZ = 0, surfaceId = 0 }))
  Assert.equal(
    runtime:_playerOccupantAt({ fieldX = 2, fieldZ = 0, surfaceId = 0, cellKey = "1:0", sourceSurfaceId = 30 }),
    "map:62:object:0",
    "the resident but inactive destination must still block through its source event"
  )
  Assert.isNil(actors.maps[destination.mapId], "a resident-but-inactive destination must not own a live actor entry")
  Assert.equal(assetProvider.acquired, 0, "read-only probing must never acquire a destination visual")

  -- Interaction discovery is wired to the same lookup collision uses, so both
  -- agree about an object on a map that owns no live actors, and the identity
  -- it hands the interaction resolver carries script and sprite semantics.
  local interactionCandidate = { fieldX = 2, fieldZ = 0, surfaceId = 0, cellKey = "1:0", sourceSurfaceId = 30 }
  local interactionActor = assert(
    runtime:_actorAt(destination.mapId, interactionCandidate),
    "a resident-but-inactive neighboring object must still supply interaction identity"
  )
  Assert.equal(
    interactionActor.sourceEvent and interactionActor.sourceEvent.scriptId,
    777,
    "interaction identity must carry the source event's script id"
  )
  Assert.equal(
    interactionActor.spriteId,
    34,
    "interaction identity must carry the variable sprite resolved from the supplied event state"
  )
  actors:dispose()
end

return { tests = T }
