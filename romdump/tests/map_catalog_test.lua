local Assert = require("tests.support.Assert")
local MapCatalog = require("romdump.src.digest.MapCatalog")

local T = {}

-- Semantic-resolution assertions, expressed against the canonical
-- *MemberId record field names used throughout the pipeline.
function T.get_elms_lab_by_symbol()
  local lab = assert(MapCatalog.get("MAP_NEW_BARK_ELMS_LAB_1F"))
  Assert.equal(lab.id, 61)
  Assert.equal(lab.matrixMemberId, 100)
  Assert.equal(lab.areaDataMemberId, 25)
  Assert.equal(lab.eventMemberId, 58)
end

function T.get_new_bark_by_symbol()
  local town = assert(MapCatalog.get("MAP_NEW_BARK"))
  Assert.equal(town.id, 60)
  Assert.equal(town.matrixMemberId, 0)
  Assert.equal(town.areaDataMemberId, 2)
  Assert.equal(town.eventMemberId, 57)
end

function T.get_by_numeric_id()
  local lab = assert(MapCatalog.get(61))
  Assert.equal(lab.symbol, "MAP_NEW_BARK_ELMS_LAB_1F")
end

function T.get_representative_non_slice_map()
  local route = assert(MapCatalog.get("MAP_ROUTE_27"))
  Assert.equal(route.id, 31)
end

function T.id_for_symbol_and_symbol_for_id()
  Assert.equal(MapCatalog.idForSymbol("MAP_NEW_BARK"), 60)
  Assert.equal(MapCatalog.symbolForId(61), "MAP_NEW_BARK_ELMS_LAB_1F")
  Assert.isNil(MapCatalog.idForSymbol("MAP_NOPE"))
  Assert.isNil(MapCatalog.symbolForId(9999))
end

function T.get_unknown_returns_error()
  local rec, err = MapCatalog.get("MAP_NOPE")
  Assert.isNil(rec)
  Assert.equal(assert(err).code, "MAP_CATALOG_UNKNOWN")

  rec, err = MapCatalog.get(9999)
  Assert.isNil(rec)
  Assert.equal(assert(err).code, "MAP_CATALOG_UNKNOWN")
end

function T.require_raises_on_unknown()
  Assert.throws(function() MapCatalog.require(4242) end)
end

function T.all_iterates_records_ascending_by_id()
  local ids = {}
  for record in MapCatalog.all() do
    ids[#ids + 1] = record.id
  end
  Assert.equal(#ids, 540)
  for i = 1, #ids do Assert.equal(ids[i], i - 1) end
end

function T.area_for_map_header()
  -- Route 27/29 neighbors reuse New Bark's area 2; EVERYWHERE filler uses area 0.
  Assert.equal(MapCatalog.areaForMapHeader(31).areaDataMemberId, 2)
  Assert.equal(MapCatalog.areaForMapHeader(33).areaDataMemberId, 2)
  Assert.equal(MapCatalog.areaForMapHeader(0).areaDataMemberId, 0)
  Assert.equal(MapCatalog.areaForMapHeader(0).symbol, "MAP_EVERYWHERE")
  Assert.equal(MapCatalog.areaForMapHeader(60).areaDataMemberId, 2)
  Assert.isNil(MapCatalog.areaForMapHeader(9999))
end

return T
