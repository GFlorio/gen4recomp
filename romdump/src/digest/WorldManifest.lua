-- Builds and persists the whole-ROM world manifest: the map index the game
-- boots and switches on. Pure build-side domain (no love); write() takes a
-- CacheFs. Source of map identity is the compiled scenes, not the ROM.

local MapAssetCache = require("libs.assets.src.MapAssetCache")
local Errors = require("libs.errors.src.Errors")

local WorldManifest = {}

-- `excluded` holds maps whose matrix cell could not be selected; `compileExcluded`
-- holds resolved maps whose asset compilation raised a structured error. The two
-- are separate collections because they mean different things: the first is a
-- map-selection limit, the second an asset-support gap with an error code and
-- context to act on.
function WorldManifest.build(entries, excluded, compileExcluded)
  local maps = {}
  for _, e in ipairs(entries) do
    maps[#maps + 1] = e
  end
  table.sort(maps, function(a, b)
    return a.id < b.id
  end)

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
  local function sortedById(records)
    local out = {}
    for _, record in ipairs(records or {}) do
      out[#out + 1] = record
    end
    table.sort(out, function(a, b)
      return a.id < b.id
    end)
    return out
  end
  local excludedMaps = sortedById(excluded)
  local compileExcludedMaps = sortedById(compileExcluded)

  -- Every map header appears exactly once across the three collections.
  local seenIds, seenSymbols = {}, {}
  for _, list in ipairs({ excludedMaps, compileExcludedMaps }) do
    for _, record in ipairs(list) do
      assert(not byId[record.id], "excluded map id is renderable: " .. record.id)
      assert(not seenIds[record.id], "duplicate excluded map id " .. record.id)
      assert(not bySymbol[record.symbol], "excluded map symbol is renderable: " .. record.symbol)
      assert(not seenSymbols[record.symbol], "duplicate excluded map symbol " .. record.symbol)
      seenIds[record.id] = true
      seenSymbols[record.symbol] = true
    end
  end
  return {
    maps = maps,
    bySymbol = bySymbol,
    byId = byId,
    analysis = {
      mapHeaderCount = #maps + #excludedMaps + #compileExcludedMaps,
      renderableCount = #maps,
      excluded = excludedMaps,
      compileExcluded = compileExcludedMaps,
    },
  }
end

function WorldManifest.write(cacheFs, entries, excluded, compileExcluded)
  local manifest = WorldManifest.build(entries, excluded, compileExcluded)
  cacheFs:writeLua(MapAssetCache.worldPath(), manifest)
  return manifest
end

return WorldManifest
