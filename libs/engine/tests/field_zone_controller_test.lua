-- FieldZoneController tests cover logical ownership changes after physical
-- coverage commits, including no-op headers and transactional preparation.

local Assert = require("tests.support.Assert")
local FieldZoneController = require("libs.engine.src.FieldZoneController")

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

function T.tests.commit_failure_discards_only_unpublished_stage()
  local staged = { state = "prepared" }
  local discarded = 0
  local controller = FieldZoneController.new({
    currentMap = { mapId = 1, mapSection = "OLD" },
    loadMap = function(mapId)
      return { mapId = mapId, mapSection = "NEW", fieldData = {} }
    end,
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

return T
