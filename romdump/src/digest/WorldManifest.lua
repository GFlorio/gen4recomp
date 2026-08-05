-- Builds and persists the whole-ROM world manifest: the map index the game
-- boots and switches on. Pure build-side domain (no love); write() takes a
-- CacheFs. Source of map identity is the compiled scenes, not the ROM.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Errors = require("libs.rom.src.Errors")

local WorldManifest = {}

function WorldManifest.build(entries, excluded)
  local maps = {}
  for _, e in ipairs(entries) do maps[#maps + 1] = e end
  table.sort(maps, function(a, b) return a.id < b.id end)

  local bySymbol, byId = {}, {}
  for index, e in ipairs(maps) do
    if byId[e.id] then
      Errors.raise("WORLD_MANIFEST_DUP_ID", "duplicate map id " .. e.id, { id = e.id })
    end
    if bySymbol[e.symbol] then
      Errors.raise("WORLD_MANIFEST_DUP_SYMBOL", "duplicate map symbol " .. e.symbol, { symbol = e.symbol })
    end
    bySymbol[e.symbol] = e.id
    byId[e.id] = index
  end
  local excludedMaps = {}
  for _, record in ipairs(excluded or {}) do excludedMaps[#excludedMaps + 1] = record end
  table.sort(excludedMaps, function(a, b) return a.id < b.id end)
  local excludedIds, excludedSymbols = {}, {}
  for _, record in ipairs(excludedMaps) do
    assert(not byId[record.id], "excluded map id is renderable: " .. record.id)
    assert(not excludedIds[record.id], "duplicate excluded map id " .. record.id)
    assert(not bySymbol[record.symbol], "excluded map symbol is renderable: " .. record.symbol)
    assert(not excludedSymbols[record.symbol], "duplicate excluded map symbol " .. record.symbol)
    excludedIds[record.id] = true
    excludedSymbols[record.symbol] = true
  end
  return {
    maps = maps,
    bySymbol = bySymbol,
    byId = byId,
    analysis = {
      mapHeaderCount = #maps + #excludedMaps,
      renderableCount = #maps,
      excluded = excludedMaps,
    },
  }
end

function WorldManifest.write(cacheFs, entries, excluded)
  local manifest = WorldManifest.build(entries, excluded)
  cacheFs:writeLua(MapAssetCache.worldPath(), manifest)
  return manifest
end

return WorldManifest
