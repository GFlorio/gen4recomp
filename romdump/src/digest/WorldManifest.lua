-- Builds and persists the whole-ROM world manifest: the map index the game
-- boots and switches on. Pure build-side domain (no love); write() takes a
-- CacheFs. Source of map identity is the compiled scenes, not the ROM.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Errors = require("libs.rom.src.Errors")

local WorldManifest = {}

function WorldManifest.build(entries)
  local maps = {}
  for _, e in ipairs(entries) do maps[#maps + 1] = e end
  table.sort(maps, function(a, b) return a.id < b.id end)

  local bySymbol, byId = {}, {}
  for index, e in ipairs(maps) do
    if bySymbol[e.symbol] then
      Errors.raise("WORLD_MANIFEST_DUP_SYMBOL", "duplicate map symbol " .. e.symbol, { symbol = e.symbol })
    end
    bySymbol[e.symbol] = e.id
    byId[e.id] = index
  end
  return { maps = maps, bySymbol = bySymbol, byId = byId }
end

function WorldManifest.write(cacheFs, entries)
  local manifest = WorldManifest.build(entries)
  cacheFs:writeLua(MapAssetCache.worldPath(), manifest)
  return manifest
end

return WorldManifest
