-- Read-only accessor over the checked-in semantic map catalog
-- (data/manifests/hgss_maps.lua). This is the only route from a semantic map id
-- or symbol to its map-header metadata. Pure domain module: no love dependency.
-- Records are immutable by convention; callers must not mutate them.

local Errors = require("src.import.Errors")
local maps = require("data.manifests.hgss_maps")

local MapCatalog = {}

-- Resolve a numeric ROM id or a MAP_* symbol to its record. Returns
-- (record | nil, err) so callers can branch without pcall.
function MapCatalog.get(idOrSymbol)
  local id = idOrSymbol
  if type(idOrSymbol) == "string" then
    id = maps.bySymbol[idOrSymbol]
  end
  local record = id ~= nil and maps.byId[id] or nil
  if not record then
    return nil, Errors.new("MAP_CATALOG_UNKNOWN",
      "no catalog record for " .. tostring(idOrSymbol),
      { key = idOrSymbol })
  end
  return record
end

function MapCatalog.require(idOrSymbol)
  local record, err = MapCatalog.get(idOrSymbol)
  if not record then error(err) end
  return record
end

-- Resolve a decoded map-header id to its area record ({ symbol,
-- areaDataMemberId }) for the neighbor-ring cells, or nil when no mapping is
-- checked in. Neighbor cells with an unknown header are simply not rendered.
function MapCatalog.areaForMapHeader(mapHeaderId)
  return maps.areaByMapHeaderId and maps.areaByMapHeaderId[mapHeaderId] or nil
end

function MapCatalog.idForSymbol(symbol)
  return maps.bySymbol[symbol]
end

function MapCatalog.symbolForId(mapId)
  local record = maps.byId[mapId]
  return record and record.symbol or nil
end

-- Stateless iterator over every record, ascending by numeric id, so callers get
-- deterministic ordering.
function MapCatalog.all()
  local ids = {}
  for id in pairs(maps.byId) do ids[#ids + 1] = id end
  table.sort(ids)
  local i = 0
  return function()
    i = i + 1
    local id = ids[i]
    if id == nil then return nil end
    return maps.byId[id]
  end
end

return MapCatalog
