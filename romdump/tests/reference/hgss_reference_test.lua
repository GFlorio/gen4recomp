-- Public invariants for the frozen HGSS reference catalogs. These tests ensure
-- snapshot structure and representative records remain intact without a ROM.

local Assert = require("tests.support.Assert")
local maps = require("romdump.src.reference.hgss.maps")
local narcs = require("romdump.src.reference.hgss.narcs")
local signpostCommands = require("romdump.src.reference.hgss.signpost_commands")

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

-- The five signpost window commands (MAPSIGNCOMMAND_*) are the source-faithful
-- command contract opcodes 57/58 decode: exactly 0..4, complete, and uniquely
-- named. The catalog encodes each code's source name and its semantic command
-- explicitly (never a runtime prefix-strip), and semanticName resolves the
-- exact mapping. The corpus and std_signpost scripts carry real command
-- values, so the mapping is pinned here once.
function T.signpost_command_constants_are_complete()
  Assert.equal(signpostCommands.schema, 1)
  local expected = {
    { 0, "MAPSIGNCOMMAND_NOP", "nop" },
    { 1, "MAPSIGNCOMMAND_SHOW", "show" },
    { 2, "MAPSIGNCOMMAND_WIPE_OUT", "wipe_out" },
    { 3, "MAPSIGNCOMMAND_WIPE_IN", "wipe_in" },
    { 4, "MAPSIGNCOMMAND_HIDE", "hide" },
  }
  local seen = {}
  for _, entry in ipairs(expected) do
    local record = assert(signpostCommands.byCode[entry[1]], "command " .. entry[1] .. " recorded")
    Assert.equal(record.sourceName, entry[2])
    Assert.equal(record.semantic, entry[3])
    Assert.equal(signpostCommands.semanticName(entry[1]), entry[3])
    Assert.isNil(seen[record.sourceName])
    seen[record.sourceName] = true
  end
  local count = 0
  for _ in pairs(signpostCommands.byCode) do
    count = count + 1
  end
  Assert.equal(count, 5)
  Assert.isNil(signpostCommands.semanticName(5), "a code outside the pinned 0..4 range resolves to nothing")
  Assert.isNil(signpostCommands.semanticName("2"), "a non-numeric code resolves to nothing")
end

return { tests = T }
