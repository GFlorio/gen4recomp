-- Field residency tests use counting owner doubles to observe logical map
-- preparation, promotion, activation, eviction, and fallback ownership.

local Assert = require("tests.support.Assert")
local FieldAudioController = require("libs.engine.src.audio.FieldAudioController")

local function coordinatorClass()
  local ok, loaded = pcall(require, "libs.engine.src.FieldResidencyCoordinator")
  Assert.isTrue(ok, "field residency coordinator production boundary is required")
  return assert(loaded)
end

---@param mapId integer
---@return RuntimeFieldMap
local function map(mapId)
  return {
    mapId = mapId,
    mapSymbol = "map-" .. mapId,
    mapSection = "section-" .. mapId,
    scene = {},
    fieldData = {},
    cameraType = 0,
    coordinateOrigin = { x = 0, z = 0 },
    release = function() end,
    updateAnimated = function() end,
  }
end

local function ids(descriptors)
  local result = {}
  local seen = {}
  for _, descriptor in ipairs(descriptors) do
    if not seen[descriptor.mapHeaderId] then
      seen[descriptor.mapHeaderId] = true
      result[#result + 1] = descriptor.mapHeaderId
    end
  end
  table.sort(result)
  return result
end

local function hasId(values, expected)
  for _, value in ipairs(values) do
    if value == expected then
      return true
    end
  end
  return false
end

local function coverageFixture()
  local coverage = {
    anchorX = 0,
    anchorZ = 0,
    committed = {
      { cellKey = "0:0", mapHeaderId = 10 },
      { cellKey = "1:0", mapHeaderId = 20 },
    },
    footprint = {
      { cellKey = "0:0", mapHeaderId = 10 },
      { cellKey = "1:0", mapHeaderId = 20 },
      { cellKey = "2:0", mapHeaderId = 30 },
    },
    destinationMapId = 10,
    physicalFallbacks = 0,
    queued = 0,
    prefetchError = nil,
  }

  function coverage:committedDescriptors()
    return self.committed
  end

  function coverage:prefetchDescriptors()
    return self.footprint
  end

  function coverage:committedMapIds()
    return ids(self.committed)
  end

  function coverage:prefetchMapIds()
    return ids(self.footprint)
  end

  function coverage:mapHeaderAt(_, _)
    return self.destinationMapId
  end

  function coverage:recenter(anchorX, anchorZ)
    self.anchorX, self.anchorZ = anchorX, anchorZ
    self.physicalFallbacks = self.physicalFallbacks + 1
  end

  function coverage:queuePrefetch()
    self.queued = 1
  end

  function coverage:updatePrefetch()
    if self.prefetchError then
      return 0
    end
    self.queued = 0
    return 0
  end

  function coverage:status()
    return {
      anchorX = self.anchorX,
      anchorZ = self.anchorZ,
      committedCount = #self.committed,
      readyPrefetchCount = math.max(0, #self.footprint - #self.committed),
      queuedPrefetchCount = self.queued,
      synchronousPhysicalFallbackLoads = self.physicalFallbacks,
      prefetchError = self.prefetchError,
    }
  end

  return coverage
end

local function logicalOwners(coverage)
  local maps = { [10] = map(10), [20] = map(20), [30] = map(30), [40] = map(40) }
  local loader = {
    maps = maps,
    loads = 0,
    protections = {},
  }
  function loader:load(mapId)
    self.loads = self.loads + 1
    return assert(self.maps[mapId])
  end
  function loader:protectMap(mapId, protected)
    self.protections[mapId] = protected and true or nil
  end

  local actors = {
    maps = {},
    prepared = {},
    prepares = 0,
    commits = 0,
    leaves = {},
    reconcileCalls = 0,
  }
  function actors:prepareMap(runtimeMap)
    self.prepares = self.prepares + 1
    local entry = { runtimeMap = runtimeMap, actors = { runtimeMap.mapId } }
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
  end
  function actors:reconcilePhysicalWorld()
    self.reconcileCalls = self.reconcileCalls + 1
  end
  function actors:setActiveMap(mapId)
    self.currentMapId = mapId
  end
  function actors:drawRecords()
    local records = {}
    for mapId in pairs(self.maps) do
      records[#records + 1] = { mapId = mapId }
    end
    table.sort(records, function(left, right)
      return left.mapId < right.mapId
    end)
    return records
  end

  local calls = {}
  local zone = {
    currentMap = maps[10],
  }
  function zone:afterCoverageCommit(_, player)
    local mapId = coverage:mapHeaderAt(player.fieldX, player.fieldZ)
    local destination = assert(loader.maps[mapId])
    if destination == self.currentMap then
      return nil
    end
    self.currentMap = destination
    calls[#calls + 1] = "activate:" .. mapId
    return { oldMapId = self.currentMap.mapId, newMapId = mapId }
  end

  return loader, actors, zone, calls
end

local function coordinatorFixture()
  local coverage = coverageFixture()
  local loader, actors, zone, calls = logicalOwners(coverage)
  local coordinator = coordinatorClass().new({
    coverage = coverage,
    mapLoader = loader,
    actors = actors,
    zoneController = zone,
    eventState = {},
  })
  return coordinator, coverage, loader, actors, zone, calls
end

local function preparedMusicAudio()
  local calls = { sequences = {}, banks = {}, sound = 0 }
  local provider = {}
  function provider:sequence(id)
    calls.sequences[#calls.sequences + 1] = id
    return { id = id, bankId = 7 }
  end
  function provider:bank(id)
    calls.banks[#calls.banks + 1] = id
    return { id = id }
  end

  local sound = {}
  local function record()
    calls.sound = calls.sound + 1
  end
  function sound:currentMusic()
    record()
    return 10
  end
  function sound:playMusic()
    record()
  end
  function sound:queueMusicReplacement()
    record()
  end
  function sound:stopMusic()
    record()
  end

  local controller = FieldAudioController.new({
    sound = sound --[[@as GameSound]],
    provider = provider --[[@as AudioAssetProvider]],
    eventState = {
      isFlagSet = function()
        return false
      end,
    },
    fieldPosition = function()
      return 0, 0
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return nil
    end,
  })
  return controller, calls
end

local function actors_remain_live_across_active_map_switch_until_their_last_cell_leaves()
  local coordinator, coverage, _, actors, zone, calls = coordinatorFixture()
  coordinator:initialize()
  Assert.deepEqual(coordinator:status().residentMapIds, { 10, 20 })
  Assert.notNil(actors.maps[10])
  Assert.notNil(actors.maps[20])
  Assert.equal(#actors:drawRecords(), 2)

  coverage.destinationMapId = 20
  coordinator:afterCommittedMove({ fieldX = 32, fieldZ = 0, currentMap = zone.currentMap })
  Assert.notNil(actors.maps[10], "the source actor remains while its cell is committed")
  Assert.notNil(actors.maps[20], "the destination actor is live before activation")
  Assert.equal(zone.currentMap.mapId, 20)
  Assert.deepEqual(calls, { "activate:20" })

  coverage.committed = { { cellKey = "1:0", mapHeaderId = 20 }, { cellKey = "2:0", mapHeaderId = 30 } }
  coverage.footprint = coverage.committed
  coverage.destinationMapId = 20
  coordinator:afterCommittedMove({ fieldX = 64, fieldZ = 0, currentMap = map(10) })
  Assert.isNil(actors.maps[10], "the source actor releases after its last committed cell leaves")
  Assert.equal(actors.leaves[10], 1)
  coordinator:dispose()
end

local function eviction_tracks_committed_map_headers_and_releases_protection_once()
  local coordinator, coverage, loader, actors = coordinatorFixture()
  coordinator:initialize()
  coordinator:updatePrefetch(1)
  Assert.isTrue(hasId(coordinator:status().preparedMapIds, 30))
  Assert.isTrue(loader.protections[10])
  Assert.isTrue(loader.protections[20])

  coverage.committed = { { cellKey = "1:0", mapHeaderId = 20 } }
  coverage.footprint = {
    { cellKey = "1:0", mapHeaderId = 20 },
    { cellKey = "3:0", mapHeaderId = 40 },
  }
  coverage.destinationMapId = 20
  coordinator:afterCommittedMove({ fieldX = 64, fieldZ = 0, currentMap = map(10) })

  local status = coordinator:status()
  Assert.deepEqual(status.residentMapIds, { 20 })
  Assert.isFalse(hasId(status.preparedMapIds, 10), "no stale prepared map remains outside the footprint")
  Assert.isFalse(hasId(status.preparedMapIds, 30), "prepared maps leave with the prefetch footprint")
  Assert.isNil(actors.maps[10])
  Assert.equal(actors.leaves[10], 1)
  Assert.isNil(loader.protections[10])
  Assert.isNil(loader.protections[30])
  coordinator:dispose()
end

local function failed_physical_prefetch_does_not_consume_the_logical_budget()
  local coordinator, coverage, _, actors = coordinatorFixture()
  coordinator:initialize()
  coverage.prefetchError = "physical prefetch failed"

  Assert.equal(coordinator:updatePrefetch(1), 0)
  Assert.deepEqual(coordinator:status().preparedMapIds, {})
  Assert.deepEqual(actors.prepared, {})
  coordinator:dispose()
end

local function prepared_hook_failure_releases_actor_and_map_ownership()
  local coverage = coverageFixture()
  local loader, actors, zone = logicalOwners(coverage)
  local coordinator = coordinatorClass().new({
    coverage = coverage,
    mapLoader = loader,
    actors = actors,
    zoneController = zone,
    eventState = {},
    onPreparedMap = function()
      error("preparation hook failed", 0)
    end,
  })

  local ok, err = pcall(function()
    coordinator:initialize()
  end)
  Assert.isFalse(ok)
  Assert.equal(err, "preparation hook failed")
  Assert.deepEqual(actors.prepared, {})
  Assert.isNil(loader.protections[10])
  coordinator:dispose()
end

local function outrunning_prefetch_keeps_the_world_coherent_and_counts_fallbacks()
  local coordinator, coverage, loader, actors, zone = coordinatorFixture()
  coverage.committed = { { cellKey = "0:0", mapHeaderId = 10 } }
  coverage.footprint = coverage.committed
  coordinator:initialize()
  local beforeLoads = loader.loads
  coverage.committed = { { cellKey = "1:0", mapHeaderId = 20 } }
  coverage.footprint = coverage.committed
  coverage.destinationMapId = 20
  coordinator:afterCommittedMove({ fieldX = 32, fieldZ = 0, currentMap = zone.currentMap })

  local status = coordinator:status()
  Assert.equal(loader.loads, beforeLoads + 1, "a missing logical map is acquired synchronously")
  Assert.equal(status.synchronousLogicalFallbackLoads, 1)
  Assert.equal(status.physical.synchronousPhysicalFallbackLoads, 1)
  Assert.equal(zone.currentMap.mapId, 20)
  Assert.notNil(actors.maps[20])
  coordinator:dispose()
end

local function prepared_map_hook_warms_music_before_activation()
  local coverage = coverageFixture()
  local loader, actors, zone = logicalOwners(coverage)
  loader.maps[30].fieldData = {
    music = { day = 20, night = 20, flagOverrides = {}, traversalOverrides = {} },
  }
  local audio, calls = preparedMusicAudio()
  local coordinator = coordinatorClass().new({
    coverage = coverage,
    mapLoader = loader,
    actors = actors,
    zoneController = zone,
    eventState = {},
    onPreparedMap = function(runtimeMap)
      if runtimeMap.mapId == 30 then
        ---@diagnostic disable-next-line: undefined-field -- acceptance contract is authored before production implementation
        local prewarmMapMusic = audio.prewarmMapMusic
        Assert.isTrue(
          type(prewarmMapMusic) == "function",
          "prepared map lifecycle must expose non-playing music metadata warmup"
        )
        prewarmMapMusic(audio, runtimeMap)
      end
    end,
  })

  coordinator:initialize()
  Assert.equal(coordinator:updatePrefetch(1), 1)

  Assert.deepEqual(calls.sequences, { 20 }, "prepared map hook must warm the map-header sequence")
  Assert.deepEqual(calls.banks, { 7 }, "prepared map hook must warm the sequence bank")
  Assert.equal(calls.sound, 0, "prepared-map warmup must not enter playback")
  Assert.deepEqual(coordinator:status().residentMapIds, { 10, 20 })
  Assert.deepEqual(coordinator:status().preparedMapIds, { 30 })
  Assert.isNil(actors.maps[30], "a prepared map must not become actor-resident before promotion")
  Assert.equal(actors.currentMapId, 10, "preparing a map must not activate it")
  Assert.equal(zone.currentMap.mapId, 10, "preparing a map must not switch the active zone")
  coordinator:dispose()
end

return {
  metadata = { capabilities = {} },
  tests = {
    actors_remain_live_across_active_map_switch_until_their_last_cell_leaves = actors_remain_live_across_active_map_switch_until_their_last_cell_leaves,
    eviction_tracks_committed_map_headers_and_releases_protection_once = eviction_tracks_committed_map_headers_and_releases_protection_once,
    failed_physical_prefetch_does_not_consume_the_logical_budget = failed_physical_prefetch_does_not_consume_the_logical_budget,
    prepared_hook_failure_releases_actor_and_map_ownership = prepared_hook_failure_releases_actor_and_map_ownership,
    outrunning_prefetch_keeps_the_world_coherent_and_counts_fallbacks = outrunning_prefetch_keeps_the_world_coherent_and_counts_fallbacks,
    prepared_map_hook_warms_music_before_activation = prepared_map_hook_warms_music_before_activation,
  },
}
