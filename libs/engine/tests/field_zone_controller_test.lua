-- FieldZoneController tests cover logical ownership changes after physical
-- coverage commits, including no-op headers and transactional preparation.

local Assert = require("tests.support.Assert")
local FieldZoneController = require("libs.engine.src.FieldZoneController")

---@class TestLogicalMap
---@field mapId integer
---@field mapSection string
---@field physicalOwner table

local T = {
  metadata = { capabilities = {} },
  tests = {},
}

function T.tests.switches_once_and_preserves_the_player()
  ---@type FieldZonePlayer
  local player = { fieldX = 0, fieldZ = 0 }
  local calls = {}
  local controller = FieldZoneController.new({
    currentMap = { mapId = 1, mapSection = "OLD" },
    loadMap = function(mapId)
      return { mapId = mapId, mapSection = "NEW", fieldData = {} }
    end,
    protectMap = function() end,
    stageActors = function(map)
      calls[#calls + 1] = "stage:" .. map.mapId
      return { mapId = map.mapId }
    end,
    commitActors = function()
      calls[#calls + 1] = "commit"
    end,
    rebindScripts = function(map)
      calls[#calls + 1] = "scripts:" .. map.mapId
    end,
  })
  ---@type FieldZoneCoverage
  local coverage = {
    currentCell = function()
      return { mapHeaderId = 2 }
    end,
  }
  local record = controller:afterCoverageCommit(coverage, player)
  assert(record ~= nil)
  Assert.equal(record.oldMapId, 1)
  Assert.equal(record.newMapId, 2)
  Assert.isTrue(controller.currentMap.mapId == 2)
  Assert.equal(table.concat(calls, ","), "stage:2,commit,scripts:2")
end

function T.tests.same_header_is_a_noop()
  local count = 0
  local controller = FieldZoneController.new({
    currentMap = { mapId = 4, mapSection = "SAME" },
    loadMap = function()
      count = count + 1
    end,
    protectMap = function() end,
  })
  ---@type FieldZoneCoverage
  local fakeCoverage = {
    currentCell = function()
      return { mapHeaderId = 4 }
    end,
  }
  ---@type FieldZonePlayer
  local fakePlayer = { fieldX = 0, fieldZ = 0 }
  local result = controller:afterCoverageCommit(fakeCoverage, fakePlayer)
  Assert.isNil(result)
  Assert.equal(count, 0)
end

function T.tests.preflight_map_lookup_loads_without_publishing_zone_state()
  local source = { mapId = 1, mapSection = "OLD" }
  local destination = { mapId = 2, mapSection = "NEW" }
  local loads = 0
  local controller = FieldZoneController.new({
    currentMap = source,
    loadMap = function(mapId, player)
      loads = loads + 1
      Assert.equal(mapId, 2)
      Assert.equal(player.fieldX, 7)
      return destination
    end,
    protectMap = function()
      error("preflight must not change protection")
    end,
    stageActors = function()
      error("preflight must not stage actors")
    end,
  })

  local result = controller:mapForPreflight(2, { fieldX = 7, fieldZ = 8 })
  Assert.equal(result, destination)
  Assert.equal(loads, 1)
  Assert.equal(controller.currentMap, source)
end

function T.tests.commit_failure_discards_only_unpublished_stage()
  local staged = { state = "prepared" }
  local discarded = 0
  local controller = FieldZoneController.new({
    currentMap = { mapId = 1, mapSection = "OLD" },
    loadMap = function(mapId)
      return { mapId = mapId, mapSection = "NEW", fieldData = {} }
    end,
    protectMap = function() end,
    stageActors = function()
      return staged
    end,
    discardActors = function(candidate)
      Assert.equal(candidate, staged)
      Assert.equal(candidate.state, "prepared")
      discarded = discarded + 1
      candidate.state = "discarded"
    end,
    actorsArePrepared = function(candidate)
      return candidate.state == "prepared"
    end,
    commitActors = function()
      error("pre-publication actor commit failed", 0)
    end,
  })

  local ok, err = pcall(function()
    controller:afterCoverageCommit({
      currentCell = function()
        return { mapHeaderId = 2 }
      end,
    }, { fieldX = 0, fieldZ = 0 })
  end)
  Assert.isFalse(ok)
  Assert.equal(err, "pre-publication actor commit failed")
  Assert.equal(discarded, 1)
  Assert.equal(controller.currentMap.mapId, 1)
end

function T.tests.protects_the_destination_without_releasing_physical_owner()
  local physicalOwner = {
    releaseCalls = 0,
    logicalEntries = {},
    protections = { [1] = true },
  }
  function physicalOwner:release()
    self.releaseCalls = self.releaseCalls + 1
  end
  function physicalOwner:protectMap(mapId, protected)
    self.protections[mapId] = protected and true or nil
  end

  local source ---@type TestLogicalMap
  source = { mapId = 1, mapSection = "OLD", physicalOwner = physicalOwner }
  local destination ---@type TestLogicalMap
  destination = { mapId = 2, mapSection = "NEW", physicalOwner = physicalOwner }
  physicalOwner.logicalEntries[1] = source
  physicalOwner.logicalEntries[2] = destination
  local controller = FieldZoneController.new({
    currentMap = source,
    loadMap = function(mapId)
      return assert(physicalOwner.logicalEntries[mapId])
    end,
    protectMap = function(mapId, protected)
      physicalOwner:protectMap(mapId, protected)
    end,
  })

  controller:afterCoverageCommit({
    currentCell = function()
      return { mapHeaderId = 2 }
    end,
  }, { fieldX = 0, fieldZ = 0 })

  Assert.isTrue(physicalOwner.protections[2], "the destination logical entry must be protected")
  Assert.isNil(physicalOwner.protections[1], "the source logical entry must become evictable")
  Assert.equal(controller.currentMap, destination)
  Assert.equal(destination.physicalOwner, physicalOwner, "logical loading must preserve physical ownership")
  Assert.equal(physicalOwner.releaseCalls, 0, "logical loading must not release the physical owner")
end

return T
