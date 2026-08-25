-- ScriptMapsService: the script-facing map/warp abstraction. Source `Warp`
-- after a completed source screen fade must perform a covered map swap
-- (reusing transition preparation/commit without a second ordinary fade
-- pair), and the source special-spawn setter (opcode 582) must leave
-- observable semantic state instead of vanishing as a noop.

local Assert = require("tests.support.Assert")
local ScriptMapsService = require("libs.engine.src.script.ScriptMapsService")

local T = {}

local function fakeLoader()
  return {
    load = function(_, ref)
      return { mapId = ref, coordinateOrigin = { x = 0, z = 0 } }
    end,
  }
end

local function fakeSourceMap()
  return { mapId = "MAP_NEW_BARK" }
end

local function target()
  return { map = "MAP_NEW_BARK_ELMS_LAB_2F", warp = 0, fieldX = 12, fieldZ = 6, facing = "west" }
end

-- A covered scripted swap must not start the ordinary FieldTransition fade
-- lifecycle when the source screen already owns opaque cover; it must use a
-- dedicated covered-swap entry point instead.
function T.a_covered_scripted_swap_never_starts_the_ordinary_transition_fade()
  local calls = {}
  local fakeTransition = {
    start = function(...)
      calls[#calls + 1] = "start"
    end,
    startCoveredSwap = function(...)
      calls[#calls + 1] = "startCoveredSwap"
    end,
  }
  local screen = {
    isOpaque = function()
      return true
    end,
  }
  local service = ScriptMapsService.new({
    transition = fakeTransition,
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
    screen = screen,
  })
  service:startWarp(target())
  Assert.deepEqual(
    calls,
    { "startCoveredSwap" },
    "a scripted warp under opaque script cover must use the covered-swap entry point, not the ordinary transition fade lifecycle"
  )
end

-- A covered swap without opaque cover is an explicit failure, never a
-- silently inserted ordinary fade.
function T.a_covered_scripted_swap_without_opaque_cover_fails_explicitly()
  local fakeTransition = {
    start = function() end,
    startCoveredSwap = function() end,
  }
  local screen = {
    isOpaque = function()
      return false
    end,
  }
  local service = ScriptMapsService.new({
    transition = fakeTransition,
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
    screen = screen,
  })
  local ok = pcall(function()
    service:startWarp(target())
  end)
  Assert.isFalse(ok, "a covered swap must require opaque screen cover before committing, not silently proceed")
end

-- Opcode 582's special-spawn setter must leave named, observable semantic
-- state on the maps service rather than disappearing as a noop.
function T.special_spawn_setter_records_source_location_and_is_observable()
  local service = ScriptMapsService.new({
    transition = { start = function() end },
    loader = fakeLoader(),
    sourceMap = fakeSourceMap(),
  })
  Assert.isNil(service:specialSpawn(), "no special spawn is recorded before the source setter runs")
  service:setSpecialSpawn({ map = "MAP_NEW_BARK", fieldX = 688, fieldZ = 393, warpId = -1, direction = "south" })
  Assert.deepEqual(service:specialSpawn(), {
    map = "MAP_NEW_BARK",
    fieldX = 688,
    fieldZ = 393,
    warpId = -1,
    direction = "south",
  })
end

return { tests = T }
