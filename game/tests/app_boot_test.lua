-- App boot-target selection tests. A bare `--field` flag must boot the runtime
-- default map rather than leaking the boolean through to the map loader.

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")

local T = {}

function T.bare_field_flag_selects_the_default_map()
  Assert.isNil(App.fieldTarget(true))
end

function T.numeric_string_is_a_map_id()
  Assert.equal(App.fieldTarget("61"), 61)
end

function T.symbol_passes_through()
  Assert.equal(App.fieldTarget("MAP_NEW_BARK_ELMS_LAB_1F"), "MAP_NEW_BARK_ELMS_LAB_1F")
end

function T.nil_passes_through()
  Assert.isNil(App.fieldTarget(nil))
end

return T
