-- Resolves physical coverage cells to logical-zone identity. The shared
-- EVERYWHERE matrix header (header 0, MAP_EVERYWHERE in the frozen
-- pokeheartgold map-header reference) owns valid physical terrain but no
-- logical map, so behavior over such a cell stays with the currently active
-- map. Every other header names its own logical map; a header the loader
-- cannot define is not filler and fails at logical acquisition instead of
-- silently inheriting the current zone. Pure domain module: no love
-- dependency.

local FieldZoneIdentity = {}

-- The one HGSS map header that is valid physical terrain without a logical
-- map. This is the single place that knows the header value; callers
-- classify through isPhysicalOnlyCell or logicalZoneAt, never by comparing
-- against 0 themselves.
FieldZoneIdentity.EVERYWHERE_MAP_HEADER = 0

---@param mapHeaderId integer
---@return boolean
function FieldZoneIdentity.isPhysicalOnlyCell(mapHeaderId)
  assert(mapHeaderId ~= nil, "physical cell map header id required")
  return mapHeaderId == FieldZoneIdentity.EVERYWHERE_MAP_HEADER
end

-- Answer which logical zone owns behavior at a coordinate: a normal cell
-- declares its own logical map, a physical-only cell inherits the currently
-- active map, and a coordinate with no physical header resolves to nil so
-- callers preserve their existing out-of-coverage behavior. Resolving
-- identity reads coverage only and never acquires a logical map.
---@param coverage table coverage exposing mapHeaderAt(fieldX, fieldZ)
---@param fieldX integer
---@param fieldZ integer
---@param currentMapId integer
---@return integer?
function FieldZoneIdentity.logicalZoneAt(coverage, fieldX, fieldZ, currentMapId)
  assert(coverage and type(coverage.mapHeaderAt) == "function", "physical coverage with mapHeaderAt required")
  assert(type(fieldX) == "number" and fieldX % 1 == 0, "logical zone fieldX required")
  assert(type(fieldZ) == "number" and fieldZ % 1 == 0, "logical zone fieldZ required")
  assert(currentMapId ~= nil, "current logical map id required")
  local header = coverage:mapHeaderAt(fieldX, fieldZ)
  if header == nil then
    return nil
  end
  if FieldZoneIdentity.isPhysicalOnlyCell(header) then
    return currentMapId
  end
  return header
end

return FieldZoneIdentity
