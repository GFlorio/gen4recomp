-- Public invariants for the frozen HGSS reference catalogs. These tests ensure
-- snapshot structure and representative records remain intact without a ROM.

local Assert = require("tests.support.Assert")
local maps = require("romdump.src.reference.hgss.maps")
local narcs = require("romdump.src.reference.hgss.narcs")

local T = {}

local BOOLEAN_FIELDS = {
  "bikeAllowed",
  "runningAllowedUnused",
  "escapeRopeAllowed",
  "flyAllowed",
  "outgoingCalls",
  "incomingCalls",
  "radioSignal",
}

local MEMBER_ID_FIELDS = {
  "wildEncounterMemberId",
  "areaDataMemberId",
  "matrixMemberId",
  "scriptsMemberId",
  "scriptHeaderMemberId",
  "messageMemberId",
  "eventMemberId",
}

function T.narc_catalog_is_complete_and_unique()
  Assert.equal(narcs.schema, 1)
  Assert.equal(narcs.count, 267)
  local ids, symbols, paths, count = {}, {}, {}, 0
  for symbol, entry in pairs(narcs.entries) do
    Assert.isTrue(symbol ~= "")
    Assert.isTrue(entry.path ~= "")
    Assert.isNil(ids[entry.narcId])
    Assert.isNil(symbols[symbol])
    Assert.isNil(paths[entry.path])
    ids[entry.narcId], symbols[symbol], paths[entry.path] = true, true, true
    count = count + 1
  end
  Assert.equal(count, 267)
  for narcId = 0, 266 do
    Assert.isTrue(ids[narcId])
  end
end

function T.map_catalog_is_complete_and_well_typed()
  Assert.equal(maps.schema, 1)
  Assert.equal(maps.count, 540)
  local symbols = {}
  for id = 0, 539 do
    local record = assert(maps.byId[id])
    Assert.equal(record.id, id)
    Assert.isTrue(record.symbol ~= "")
    Assert.isNil(symbols[record.symbol])
    symbols[record.symbol] = true
    for _, field in ipairs(BOOLEAN_FIELDS) do
      Assert.equal(type(record[field]), "boolean")
    end
    for _, field in ipairs(MEMBER_ID_FIELDS) do
      Assert.equal(type(record[field]), "number")
    end
  end
end

function T.map_catalog_boundaries_are_stable()
  Assert.equal(maps.byId[0].symbol, "MAP_EVERYWHERE")
  Assert.equal(maps.byId[539].symbol, "MAP_POKEMON_LEAGUE_ENTRANCE_WIFI_ROOM")
end

function T.new_bark_records_are_stable()
  local town = maps.byId[60]
  Assert.equal(town.symbol, "MAP_NEW_BARK")
  Assert.deepEqual({
    town.matrixMemberId,
    town.areaDataMemberId,
    town.scriptsMemberId,
    town.scriptHeaderMemberId,
    town.messageMemberId,
    town.eventMemberId,
  }, { 0, 2, 842, 615, 542, 57 })

  local lab = maps.byId[61]
  Assert.equal(lab.symbol, "MAP_NEW_BARK_ELMS_LAB_1F")
  Assert.deepEqual({
    lab.matrixMemberId,
    lab.areaDataMemberId,
    lab.scriptsMemberId,
    lab.scriptHeaderMemberId,
    lab.messageMemberId,
    lab.eventMemberId,
  }, { 100, 25, 843, 616, 543, 58 })
end

return { metadata = { layer = "unit" }, tests = T }
