-- Resolves a map symbol or id against the cache world manifest. The game's only
-- source of map identity; replaces the ROM-facing MapCatalog on the runtime path.

local Errors = require("libs.rom.src.Errors")

local WorldLookup = {}

function WorldLookup.get(world, idOrSymbol)
  local id = type(idOrSymbol) == "string" and world.bySymbol[idOrSymbol] or idOrSymbol
  local index = id ~= nil and world.byId[id] or nil
  return index and world.maps[index] or nil
end

function WorldLookup.require(world, idOrSymbol)
  local rec = WorldLookup.get(world, idOrSymbol)
  if not rec then
    Errors.raise("WORLD_LOOKUP_UNKNOWN", "no manifest entry for " .. tostring(idOrSymbol), { key = idOrSymbol })
  end
  return rec
end

return WorldLookup
