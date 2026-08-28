-- Production ownership seams for discontinuous field-map changes. The
-- physical coverage doubles are deterministic; logical membership still runs
-- through the real residency coordinator and the runtime commit boundary.

local Assert = require("tests.support.Assert")
local FieldResidencyCoordinator = require("libs.engine.src.FieldResidencyCoordinator")
local FieldRuntime = require("game.src.game.FieldRuntime")

local T = {}

local function map(mapId, sceneType)
  return {
    mapId = mapId,
    scene = { type = sceneType or "outdoor" },
    fieldData = { events = { objects = {} } },
    cameraType = 0,
    coordinateOrigin = { x = 0, z = 0 },
  }
end

local function coverage(name, descriptors, destinationMapId)
  local owner = {
    name = name,
    anchorX = 0,
    anchorZ = 0,
    committed = descriptors,
    footprint = descriptors,
    destinationMapId = destinationMapId,
    releases = 0,
    released = false,
    updates = 0,
    queues = 0,
  }
  function owner:committedDescriptors()
    Assert.isFalse(self.released, self.name .. " was used after release")
    return self.committed
  end
  function owner:prefetchDescriptors()
    Assert.isFalse(self.released, self.name .. " was used after release")
    return self.footprint
  end
  function owner:mapHeaderAt()
    Assert.isFalse(self.released, self.name .. " was used after release")
    return self.destinationMapId
  end
  function owner:containsGlobal()
    Assert.isFalse(self.released, self.name .. " was used after release")
    return true
  end
  function owner:queuePrefetch()
    Assert.isFalse(self.released, self.name .. " was used after release")
    self.queues = self.queues + 1
  end
  function owner:updatePrefetch()
    Assert.isFalse(self.released, self.name .. " was used after release")
    self.updates = self.updates + 1
    return 0
  end
  function owner:status()
    return {
      anchorX = self.anchorX,
      anchorZ = self.anchorZ,
      committedCount = #self.committed,
      readyPrefetchCount = #self.footprint,
      queuedPrefetchCount = 0,
    }
  end
  function owner:release()
    Assert.isFalse(self.released, self.name .. " was released twice")
    self.released = true
    self.releases = self.releases + 1
  end
  return owner
end

local function runtimeView(logicalMap, physicalCoverage)
  return {
    mapId = logicalMap.mapId,
    scene = logicalMap.scene,
    fieldData = logicalMap.fieldData,
    cameraType = logicalMap.cameraType,
    coordinateOrigin = logicalMap.coordinateOrigin,
    coverage = physicalCoverage,
    logicalMap = logicalMap,
  }
end

local function fixture(options)
  options = options or {}
  local maps = {
    [10] = map(10),
    [20] = map(20),
    [30] = map(30),
    [40] = map(40),
    [50] = map(50, "indoor"),
  }
  local sourceCoverage = coverage("source", options.sourceDescriptors or { { mapHeaderId = 10 } }, 10)
  local loader = {
    maps = maps,
    loads = 0,
    protections = {},
    protectionCalls = {},
  }
  function loader:load(mapId)
    self.loads = self.loads + 1
    return assert(self.maps[mapId])
  end
  function loader:protectMap(mapId, protected)
    self.protectionCalls[mapId] = (self.protectionCalls[mapId] or 0) + 1
    self.protections[mapId] = protected and true or nil
  end

  local actors = {
    maps = {},
    prepared = {},
    prepares = 0,
    commits = 0,
    leaves = {},
    rebinds = 0,
    currentMapId = nil,
    coverage = sourceCoverage,
  }
  function actors:prepareMap(runtimeMap)
    self.prepares = self.prepares + 1
    local actor = {
      actorId = "actor-" .. runtimeMap.mapId,
      fieldX = 4,
      fieldZ = 5,
      facing = "east",
      visible = true,
    }
    local entry = {
      runtimeMap = runtimeMap,
      actors = { actor },
      order = { actor },
      actor = actor,
      resident = false,
    }
    local prepared = { entry = entry, state = "prepared" }
    self.prepared[runtimeMap.mapId] = prepared
    return prepared
  end
  function actors:commitPrepared(prepared)
    self.commits = self.commits + 1
    local mapId = prepared.entry.runtimeMap.mapId
    self.maps[mapId] = prepared.entry
    self.prepared[mapId] = nil
    prepared.state = "committed"
  end
  function actors:discardPrepared(prepared)
    self.prepared[prepared.entry.runtimeMap.mapId] = nil
    prepared.state = "discarded"
  end
  function actors:leaveMap(mapId)
    self.maps[mapId] = nil
    self.leaves[mapId] = (self.leaves[mapId] or 0) + 1
    if self.currentMapId == mapId then
      self.currentMapId = nil
    end
  end
  function actors:rebindMap(mapId, runtimeMap)
    local entry = assert(self.maps[mapId])
    Assert.equal(runtimeMap.mapId, mapId)
    entry.runtimeMap = runtimeMap
    self.rebinds = self.rebinds + 1
  end
  function actors:reconcilePhysicalWorld()
    local committed = {}
    for _, descriptor in ipairs(self.coverage:committedDescriptors()) do
      committed[descriptor.mapHeaderId] = true
    end
    for mapId, entry in pairs(self.maps) do
      entry.resident = committed[mapId] == true
    end
  end
  function actors:setActiveMap(mapId)
    Assert.notNil(self.maps[mapId], "active actor map must be resident")
    self.currentMapId = mapId
  end

  local coordinator = FieldResidencyCoordinator.new({
    coverage = sourceCoverage,
    mapLoader = loader,
    actors = actors,
    zoneController = { currentMap = maps[10] },
    eventState = {},
    composeMap = function(logicalMap, physicalCoverage)
      if physicalCoverage then
        return runtimeView(logicalMap, physicalCoverage)
      end
      return logicalMap
    end,
    onPreparedMap = options.onPreparedMap,
  })
  coordinator:initialize()

  local runtime = setmetatable({
    physicalCoverage = sourceCoverage,
    runtimeMap = maps[10],
    residency = coordinator,
    actors = actors,
    mapLoader = loader,
    transition = {
      phase = "idle",
      fadeAlpha = 1,
      player = nil,
      consumeCompleted = function()
        return false
      end,
      updateSourceFrame = function() end,
    },
    session = {
      accumulator = 0,
      currentMap = maps[10],
      updateFixed = function() end,
    },
    scripts = { onMapSwap = function() end },
    zoneController = { currentMap = maps[10] },
    fieldTerrainEffectController = { clear = function() end },
    applicationHost = {
      error = function()
        return nil
      end,
    },
    presentationFrameAccumulator = 0,
  }, FieldRuntime)
  return {
    actors = actors,
    coordinator = coordinator,
    loader = loader,
    maps = maps,
    runtime = runtime,
    sourceCoverage = sourceCoverage,
  }
end

local function requireTransitionBoundary(coordinator)
  Assert.isTrue(
    type(coordinator.prepareTransition) == "function",
    "warp residency preparation must be owned by the live coordinator"
  )
  Assert.isTrue(
    type(coordinator.commitTransition) == "function",
    "warp residency publication must be owned by the live coordinator"
  )
end

local function prepare(coordinator, destinationMap, destinationCoverage)
  requireTransitionBoundary(coordinator)
  return coordinator:prepareTransition(
    destinationMap --[[@as RuntimeFieldMap]],
    destinationCoverage --[[@as FieldCoverage?]]
  )
end

function T.replacement_warp_keeps_runtime_and_logical_owner_together()
  local f = fixture()
  local destinationCoverage = coverage("destination", { { mapHeaderId = 20 } }, 20)
  local destination = runtimeView(f.maps[20], destinationCoverage)
  local transaction = prepare(f.coordinator, destination, destinationCoverage)
  local physical = {
    coverage = destinationCoverage,
    replacement = true,
    previous = f.sourceCoverage,
    state = "prepared",
  }

  f.runtime:_commitSwap(
    { destinationMap = destination },
    "south",
    { player = {}, camera = {}, playerVisual = {}, physical = physical, residency = transaction }
  )

  Assert.equal(f.runtime.physicalCoverage, destinationCoverage)
  Assert.equal(f.coordinator.coverage, destinationCoverage)
  Assert.equal(f.sourceCoverage.releases, 1)
  Assert.deepEqual(f.coordinator:status().residentMapIds, { 20 })
  f.runtime:update(1 / 30)
  Assert.equal(destinationCoverage.updates, 1, "the next runtime update uses the destination owner")
end

function T.failed_warp_preparation_preserves_source_logical_and_physical_state()
  local destinationCoverage = coverage("destination", { { mapHeaderId = 20 }, { mapHeaderId = 30 } }, 20)
  local failedMapId = 30
  local f = fixture({
    onPreparedMap = function(runtimeMap)
      if runtimeMap.mapId == failedMapId then
        error("destination logical preparation failed", 0)
      end
    end,
  })
  local sourceEntry = assert(f.actors.maps[10])
  local sourceActor = sourceEntry.actor
  local physical = {
    coverage = destinationCoverage,
    replacement = true,
    previous = f.sourceCoverage,
    state = "prepared",
  }
  local destination = runtimeView(f.maps[20], destinationCoverage)

  requireTransitionBoundary(f.coordinator)
  local ok, err = pcall(function()
    return f.coordinator:prepareTransition(
      destination --[[@as RuntimeFieldMap]],
      destinationCoverage --[[@as FieldCoverage]]
    )
  end)
  Assert.isFalse(ok)
  Assert.equal(tostring(err), "destination logical preparation failed")
  Assert.equal(f.actors.maps[10], sourceEntry)
  Assert.equal(f.actors.maps[10].actor, sourceActor)
  Assert.equal(f.actors.currentMapId, 10)
  Assert.equal(f.coordinator.coverage, f.sourceCoverage)
  Assert.isTrue(f.loader.protections[10])
  Assert.isNil(f.actors.maps[20])
  Assert.isNil(f.actors.maps[30])
  Assert.isNil(f.loader.protections[20])
  Assert.isNil(f.loader.protections[30])

  f.runtime:_disposePreparedSwap(nil, { physical = physical })
  Assert.equal(destinationCoverage.releases, 1)
  Assert.equal(f.sourceCoverage.releases, 0)
end

function T.indoor_and_outdoor_round_trip_keeps_each_owner_valid()
  local f = fixture()
  local indoor = f.maps[50]
  local indoorTransaction = prepare(f.coordinator, indoor, nil)
  f.runtime:_commitSwap(
    { destinationMap = indoor },
    "south",
    { player = {}, camera = {}, playerVisual = {}, residency = indoorTransaction }
  )

  Assert.isNil(f.coordinator.coverage)
  Assert.equal(f.runtime.physicalCoverage, f.sourceCoverage)
  f.runtime:update(1 / 30)
  Assert.equal(f.sourceCoverage.updates, 0, "indoor maintenance does not consult outdoor coverage")

  local destinationCoverage = coverage("destination", { { mapHeaderId = 20 } }, 20)
  local destination = runtimeView(f.maps[20], destinationCoverage)
  local outdoorTransaction = prepare(f.coordinator, destination, destinationCoverage)
  local physical = {
    coverage = destinationCoverage,
    replacement = true,
    previous = f.sourceCoverage,
    state = "prepared",
  }
  f.runtime:_commitSwap(
    { destinationMap = destination },
    "north",
    { player = {}, camera = {}, playerVisual = {}, physical = physical, residency = outdoorTransaction }
  )

  Assert.equal(f.coordinator.coverage, destinationCoverage)
  Assert.equal(f.runtime.physicalCoverage, destinationCoverage)
  Assert.equal(f.sourceCoverage.releases, 1)
  f.runtime:update(1 / 30)
  Assert.equal(destinationCoverage.updates, 1, "outdoor maintenance resumes on the new owner")
  Assert.deepEqual(f.coordinator:status().residentMapIds, { 20 })
end

function T.resident_destination_rebind_preserves_actor_identity_and_state()
  local f = fixture({
    sourceDescriptors = {
      { mapHeaderId = 10 },
      { mapHeaderId = 20 },
    },
  })
  f.sourceCoverage.footprint = f.sourceCoverage.committed
  f.coordinator:updatePrefetch()
  local destinationEntry = assert(f.actors.maps[20])
  local actor = destinationEntry.actor
  actor.fieldX = 17
  actor.fieldZ = 23
  actor.facing = "west"
  actor.visible = false
  local prepareCount = f.actors.prepares
  local protectionCalls = f.loader.protectionCalls[20]
  local destinationCoverage = coverage("destination", { { mapHeaderId = 20 } }, 20)
  local destination = runtimeView(f.maps[20], destinationCoverage)

  local transaction = prepare(f.coordinator, destination, destinationCoverage)
  f.coordinator:commitTransition(transaction)

  Assert.equal(f.actors.maps[20], destinationEntry)
  Assert.equal(f.actors.maps[20].actor, actor)
  Assert.equal(actor.fieldX, 17)
  Assert.equal(actor.fieldZ, 23)
  Assert.equal(actor.facing, "west")
  Assert.isFalse(actor.visible)
  Assert.equal(f.actors.maps[20].runtimeMap, destination)
  Assert.equal(f.actors.prepares, prepareCount)
  Assert.equal(f.loader.protectionCalls[20], protectionCalls)
  Assert.equal(f.actors.rebinds, 1)
end

return {
  metadata = { capabilities = {} },
  tests = T,
}
