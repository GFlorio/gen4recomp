-- FieldZoneController tests cover active logical-map selection after physical
-- coverage commits. Residency, protection, and actor ownership are external.

local Assert = require("tests.support.Assert")
local FieldZoneController = require("libs.hgss.src.field.FieldZoneController")

local function newController(options)
  local ok, result = pcall(FieldZoneController.new, options)
  Assert.isTrue(ok, "active-only zone controller must accept a resident lookup: " .. tostring(result))
  return assert(result)
end

local function controllerFor(source, destination, calls)
  return newController({
    currentMap = source,
    mapForId = function(mapId)
      calls.lookup = calls.lookup + 1
      return mapId == destination.mapId and destination or nil
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

local function switches_to_a_resident_map_and_preserves_active_side_effect_order()
  local source = { mapId = 1, mapSection = "OLD", fieldData = {} }
  local destination = { mapId = 2, mapSection = "NEW", fieldData = {} }
  local calls = { lookup = 0 }
  local controller = controllerFor(source, destination, calls)
  local player = { fieldX = 31, fieldZ = 4 }

  local change = assert(controller:afterCoverageCommit({
    mapHeaderAt = function(_, fieldX, fieldZ)
      Assert.equal(fieldX, player.fieldX)
      Assert.equal(fieldZ, player.fieldZ)
      return destination.mapId
    end,
  }, player))

  Assert.equal(change.oldMapId, source.mapId)
  Assert.equal(change.newMapId, destination.mapId)
  Assert.equal(controller.currentMap, destination)
  Assert.equal(calls.lookup, 1)
  Assert.equal(table.concat(calls, ","), "scripts:2,weather:2,audio:2,change:2")
end

local function same_header_is_a_noop_without_lookup_or_side_effects()
  local calls = { lookup = 0 }
  local source = { mapId = 4, mapSection = "SAME", fieldData = {} }
  local controller = newController({
    currentMap = source,
    mapForId = function()
      calls.lookup = calls.lookup + 1
      return nil
    end,
  })

  local result = controller:afterCoverageCommit({
    mapHeaderAt = function()
      return source.mapId
    end,
  }, { fieldX = 0, fieldZ = 0 })

  Assert.isNil(result)
  Assert.equal(calls.lookup, 0)
end

local function missing_resident_destination_is_a_programming_fault()
  local calls = { lookup = 0 }
  local source = { mapId = 1, mapSection = "OLD", fieldData = {} }
  local controller = newController({
    currentMap = source,
    mapForId = function()
      calls.lookup = calls.lookup + 1
      return nil
    end,
  })

  local err = Assert.throws(function()
    controller:afterCoverageCommit({
      mapHeaderAt = function()
        return 2
      end,
    }, { fieldX = 0, fieldZ = 0 })
  end)

  Assert.isTrue(tostring(err):find("resident", 1, true) ~= nil)
  Assert.equal(calls.lookup, 1)
  Assert.equal(controller.currentMap, source)
end

return {
  metadata = { capabilities = {} },
  tests = {
    switches_to_a_resident_map_and_preserves_active_side_effect_order = switches_to_a_resident_map_and_preserves_active_side_effect_order,
    same_header_is_a_noop_without_lookup_or_side_effects = same_header_is_a_noop_without_lookup_or_side_effects,
    missing_resident_destination_is_a_programming_fault = missing_resident_destination_is_a_programming_fault,
  },
}
