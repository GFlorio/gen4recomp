-- Physical-cell identity vs logical-zone identity: filler cells carrying the
-- shared EVERYWHERE header must not leak raw header 0 into logical-map
-- behavior. A header-0 commit keeps the current logical map with no lookup
-- of map 0 and no zone side effects; an unsupported non-zero header still
-- fails loudly instead of silently inheriting the current zone.

local Assert = require("tests.support.Assert")
local FieldZoneController = require("libs.hgss.src.field.FieldZoneController")
local FieldNavigationBoundary = require("libs.hgss.src.field.FieldNavigationBoundary")

local T = {}

local EVERYWHERE_HEADER = 0
local NEW_BARK_MAP_ID = 60

local function newZone(currentMapId, calls)
  return FieldZoneController.new({
    currentMap = { mapId = currentMapId, mapSection = "OLD", fieldData = {} },
    mapForId = function(mapId)
      calls.lookups[#calls.lookups + 1] = mapId
      error("logical lookup for map " .. tostring(mapId) .. " is not part of this contract", 0)
    end,
    rebindScripts = function(map)
      calls[#calls + 1] = "scripts:" .. map.mapId
    end,
    applyWeather = function(map)
      calls[#calls + 1] = "weather:" .. map.mapId
    end,
    enterAudio = function(map)
      calls[#calls + 1] = "audio:" .. map.mapId
    end,
    onChange = function(change)
      calls[#calls + 1] = "change:" .. change.newMapId
    end,
  })
end

local function headerCoverage(headerId)
  return {
    mapHeaderAt = function(_, _, _)
      return headerId
    end,
  }
end

function T.filler_commit_keeps_current_logical_map_without_lookup_or_side_effects()
  local calls = { lookups = {} }
  local controller = newZone(NEW_BARK_MAP_ID, calls)
  local before = controller.currentMap

  local ok, result = pcall(function()
    return controller:afterCoverageCommit(headerCoverage(EVERYWHERE_HEADER), { fieldX = 1, fieldZ = 1 })
  end)
  Assert.isTrue(ok, "a physical-only filler commit must not raise a logical-map lookup: " .. tostring(result))
  Assert.isNil(result, "a filler commit publishes no zone change")
  Assert.equal(controller.currentMap, before, "the current logical map stays active over filler")
  Assert.equal(controller.currentMap.mapId, NEW_BARK_MAP_ID)
  Assert.deepEqual(calls.lookups, {}, "no logical lookup for map 0 occurs")
  Assert.deepEqual(calls, { lookups = {} }, "no zone side effect fires for a filler commit")
end

function T.unsupported_header_is_not_silent_filler()
  local calls = { lookups = {} }
  local controller = FieldZoneController.new({
    currentMap = { mapId = NEW_BARK_MAP_ID, mapSection = "OLD", fieldData = {} },
    mapForId = function(mapId)
      calls.lookups[#calls.lookups + 1] = mapId
      return nil
    end,
  })

  local err = Assert.throws(function()
    controller:afterCoverageCommit(headerCoverage(999), { fieldX = 1, fieldZ = 1 })
  end)
  Assert.isTrue(tostring(err):find("resident", 1, true) ~= nil, "an unsupported map fails loudly: " .. tostring(err))
  Assert.deepEqual(calls.lookups, { 999 })
  Assert.equal(controller.currentMap.mapId, NEW_BARK_MAP_ID)
end

function T.missing_coverage_cell_still_fails_loudly()
  local calls = { lookups = {} }
  local controller = newZone(NEW_BARK_MAP_ID, calls)

  local err = Assert.throws(function()
    controller:afterCoverageCommit(headerCoverage(nil), { fieldX = 1, fieldZ = 1 })
  end)
  Assert.isTrue(tostring(err):find("map header", 1, true) ~= nil, "out-of-coverage stays loud: " .. tostring(err))
  Assert.equal(controller.currentMap.mapId, NEW_BARK_MAP_ID)
end

function T.seam_prediction_ignores_physical_only_filler()
  local boundary = FieldNavigationBoundary.new({
    coverageProvider = function()
      return headerCoverage(EVERYWHERE_HEADER)
    end,
    zoneController = { currentMap = { mapId = NEW_BARK_MAP_ID } },
  })
  local runtimeMap = { scene = { type = "outdoor" } }

  Assert.isFalse(
    boundary:crossesLogicalZone(runtimeMap, { fieldX = 4, fieldZ = 4 }, "north"),
    "a 60 -> 0 header change resolving to logical map 60 is not a logical seam"
  )
end

function T.seam_prediction_reports_a_real_logical_neighbor()
  local boundary = FieldNavigationBoundary.new({
    coverageProvider = function()
      return headerCoverage(61)
    end,
    zoneController = { currentMap = { mapId = NEW_BARK_MAP_ID } },
  })
  local runtimeMap = { scene = { type = "outdoor" } }

  Assert.isTrue(boundary:crossesLogicalZone(runtimeMap, { fieldX = 4, fieldZ = 4 }, "north"))
end

return { metadata = { capabilities = {} }, tests = T }
