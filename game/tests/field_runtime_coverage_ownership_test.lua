-- FieldRuntime owns the committed physical coverage. A transition may stage a
-- replacement, but only a successful commit transfers ownership; teardown is
-- repeat-safe for every committed owner.

local Assert = require("tests.support.Assert")
local FieldNavigationBoundary = require("libs.engine.src.FieldNavigationBoundary")
local FieldTransition = require("libs.engine.src.FieldTransition")
local FieldRuntime = require("game.src.game.FieldRuntime")

local T = {}

local function releaseSpy(name)
  local spy = {
    name = name,
    releases = 0,
    released = false,
    probes = 0,
  }
  function spy:release()
    Assert.isFalse(self.released, self.name .. " must not be released twice")
    self.released = true
    self.releases = self.releases + 1
  end
  function spy:mapHeaderAt()
    Assert.isFalse(self.released, self.name .. " must remain usable")
    self.probes = self.probes + 1
    return 60
  end
  function spy:probe()
    Assert.isFalse(self.released, self.name .. " must remain usable")
    self.probes = self.probes + 1
    return self.name
  end
  return spy
end

local function newSourceMap()
  return { mapId = 61 }
end

function T.destination_preparation_failure_discards_only_the_staged_owner()
  local sourceCoverage = releaseSpy("source")
  local destinationCoverage = releaseSpy("destination")
  local source = newSourceMap()
  local destination = { mapId = 60 }
  local runtime = {
    physicalCoverage = sourceCoverage,
    currentMap = source,
  }
  local cleanupCalls = 0
  local transition = FieldTransition.new({
    loader = {},
    resolveDestination = function()
      return {
        destinationMap = destination,
        fieldX = 0,
        fieldZ = 0,
        surfaceId = 0,
        worldY = 0,
        physical = {
          coverage = destinationCoverage,
          replacement = true,
          previous = sourceCoverage,
        },
      }
    end,
    prepare = function(result)
      Assert.equal(runtime.physicalCoverage, sourceCoverage)
      Assert.equal(result.physical.coverage, destinationCoverage)
      error("destination actor preparation failed", 0)
    end,
    disposePrepared = function(result)
      cleanupCalls = cleanupCalls + 1
      if result.physical and result.physical.replacement then
        result.physical.coverage:release()
      end
    end,
    commit = function()
      error("a failed preparation must not commit", 0)
    end,
  })

  transition:start(source, { warp = { index = 0, destinationMapId = 60, destinationWarpId = 0 } }, "south")
  for _ = 1, 4 do
    transition:updateSourceFrame()
    transition:updateSourceFrame()
    transition:updateFixed()
  end

  Assert.equal(transition.phase, "idle")
  Assert.equal(tostring(transition.error), "destination actor preparation failed")
  Assert.equal(runtime.physicalCoverage, sourceCoverage)
  Assert.equal(runtime.currentMap, source)
  Assert.equal(sourceCoverage.releases, 0)
  Assert.equal(destinationCoverage.releases, 1)
  Assert.equal(cleanupCalls, 1)
  Assert.equal(sourceCoverage:probe(), "source")
end

local function runtimeForSwap(sourceCoverage)
  local sourceRuntimeMap = { mapId = 61 }
  local runtime = setmetatable({
    physicalCoverage = sourceCoverage,
    runtimeMap = sourceRuntimeMap,
    transition = FieldTransition.new({ loader = {}, prepare = function() end, commit = function() end }),
    session = {},
    zoneController = { currentMap = sourceRuntimeMap },
    fieldTerrainEffectController = { clear = function() end },
    actors = { leaveMap = function() end, dispose = function() end },
    mapLoader = { protectMap = function() end, release = function() end },
    scripts = { onMapSwap = function() end },
  }, FieldRuntime)
  return runtime, sourceRuntimeMap
end

local function destinationMap(coverage)
  return {
    mapId = 60,
    coverage = coverage,
    scene = { type = "outdoor" },
  }
end

---@param runtimeMap table
---@param physicalCoverage table?
---@param actors table
---@param zoneController table
---@param player table?
---@param eventState table?
---@return table
local function occupancyRuntime(runtimeMap, physicalCoverage, actors, zoneController, player, eventState)
  return setmetatable({
    physicalCoverage = physicalCoverage,
    runtimeMap = runtimeMap,
    actors = actors,
    zoneController = zoneController,
    player = player or {},
    eventState = eventState or {},
  }, FieldRuntime)
end

local function preparedSwap(coverage, previous)
  return {
    player = {},
    camera = {},
    playerVisual = {},
    physical = {
      coverage = coverage,
      replacement = true,
      previous = previous,
      state = "prepared",
    },
  }
end

function T.successful_swap_publishes_the_new_owner_before_destination_queries()
  local sourceCoverage = releaseSpy("source")
  local destinationCoverage = releaseSpy("destination")
  local runtime, sourceRuntimeMap = runtimeForSwap(sourceCoverage)
  local destination = destinationMap(destinationCoverage)

  runtime:_commitSwap({ destinationMap = destination }, "south", preparedSwap(destinationCoverage, sourceCoverage))

  Assert.equal(runtime.physicalCoverage, destinationCoverage)
  Assert.equal(sourceCoverage.releases, 1)
  Assert.equal(destinationCoverage.releases, 0)
  Assert.equal(runtime.runtimeMap, destination)

  local boundary = FieldNavigationBoundary.new({
    zoneController = { currentMap = destination },
    coverageProvider = function()
      return runtime.physicalCoverage
    end,
  })
  Assert.isFalse(boundary:crossesLogicalZone({ scene = { type = "outdoor" } }, { fieldX = 0, fieldZ = 0 }, "south"))
  Assert.equal(sourceCoverage.probes, 0)
  Assert.equal(destinationCoverage.probes, 1)
  Assert.equal(sourceRuntimeMap.mapId, 61)

  runtime:_releaseAll()
  runtime:_releaseAll()
  Assert.equal(sourceCoverage.releases, 1)
  Assert.equal(destinationCoverage.releases, 1)
end

function T.runtime_disposal_discards_an_uncommitted_replacement()
  local sourceCoverage = releaseSpy("source")
  local destinationCoverage = releaseSpy("destination")
  local runtime = runtimeForSwap(sourceCoverage)
  runtime.transition = FieldTransition.new({ loader = {}, prepare = function() end, commit = function() end })
  runtime.transition.resolution = {
    physical = {
      coverage = destinationCoverage,
      replacement = true,
      previous = sourceCoverage,
      state = "prepared",
    },
  }

  runtime:_releaseAll()

  Assert.equal(sourceCoverage.releases, 1)
  Assert.equal(destinationCoverage.releases, 1)
end

function T.indoor_occupancy_uses_the_current_map_actor_index()
  local calls = { getAt = 0, preflight = 0 }
  local retainedCoverage = {
    mapHeaderCalls = 0,
  }
  function retainedCoverage:mapHeaderAt()
    self.mapHeaderCalls = self.mapHeaderCalls + 1
    error("retained coverage must not participate in indoor occupancy", 0)
  end

  local actors = {}
  function actors:getAt(mapId, fieldX, fieldZ, surfaceId)
    calls.getAt = calls.getAt + 1
    Assert.equal(mapId, "indoor")
    Assert.equal(fieldX, 12)
    Assert.equal(fieldZ, 8)
    Assert.equal(surfaceId, 3)
    return { actorId = "indoor-blocker" }
  end
  function actors:probeAt()
    error("indoor occupancy must not preflight a destination map", 0)
  end

  local zoneController = {}
  function zoneController:mapForPreflight()
    calls.preflight = calls.preflight + 1
    error("indoor occupancy must not load a destination map", 0)
  end

  local runtime = occupancyRuntime({ mapId = "indoor", coverage = nil }, retainedCoverage, actors, zoneController)

  local occupant = runtime:_playerOccupantAt(12, 8, 3)

  Assert.equal(occupant, "indoor-blocker")
  Assert.equal(calls.getAt, 1)
  Assert.equal(calls.preflight, 0)
  Assert.equal(retainedCoverage.mapHeaderCalls, 0)
end

function T.outdoor_seam_occupancy_preflights_destination_actors()
  local calls = { mapHeaderAt = 0, getAt = 0, mapForPreflight = 0, probeAt = 0 }
  local player = {}
  local eventState = {}
  local destination = { mapId = "destination" }
  local activeCoverage = {}
  function activeCoverage:mapHeaderAt(fieldX, fieldZ)
    calls.mapHeaderAt = calls.mapHeaderAt + 1
    Assert.equal(fieldX, 19)
    Assert.equal(fieldZ, 7)
    return "destination"
  end

  local actors = {}
  function actors:getAt()
    calls.getAt = calls.getAt + 1
    error("an outdoor seam must probe the destination map", 0)
  end
  function actors:probeAt(map, state, fieldX, fieldZ, surfaceId)
    calls.probeAt = calls.probeAt + 1
    Assert.equal(map, destination)
    Assert.equal(state, eventState)
    Assert.equal(fieldX, 19)
    Assert.equal(fieldZ, 7)
    Assert.equal(surfaceId, 2)
    return { actorId = "destination-blocker" }
  end

  local zoneController = {}
  function zoneController:mapForPreflight(mapId, requestedPlayer)
    calls.mapForPreflight = calls.mapForPreflight + 1
    Assert.equal(mapId, "destination")
    Assert.equal(requestedPlayer, player)
    return destination
  end

  local runtime =
    occupancyRuntime({ mapId = "source", coverage = activeCoverage }, nil, actors, zoneController, player, eventState)

  local occupant = runtime:_playerOccupantAt(19, 7, 2)

  Assert.equal(occupant, "destination-blocker")
  Assert.equal(calls.mapHeaderAt, 1)
  Assert.equal(calls.mapForPreflight, 1)
  Assert.equal(calls.probeAt, 1)
  Assert.equal(calls.getAt, 0)
end

return { tests = T }
