local Assert = require("tests.support.Assert")
local WorldLookup = require("game.src.game.WorldLookup")

local T = {}

local function world()
  return { maps = { { id = 60, symbol = "MAP_NEW_BARK" }, { id = 61, symbol = "MAP_ELM" } },
           bySymbol = { MAP_NEW_BARK = 60, MAP_ELM = 61 }, byId = { [60] = 1, [61] = 2 } }
end

function T.resolves_symbol_and_id()
  Assert.equal(WorldLookup.require(world(), "MAP_ELM").id, 61)
  Assert.equal(WorldLookup.require(world(), 60).symbol, "MAP_NEW_BARK")
end

function T.raises_on_unknown()
  Assert.throws(function() WorldLookup.require(world(), "MAP_NOPE") end)
end

return T
