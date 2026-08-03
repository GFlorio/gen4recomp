local Assert = require("tests.support.Assert")
local Hgss = require("data.manifests.hgss")

local T = {}

function T.resolves_friendly_alias_to_full_entry()
  local e = Hgss.resolve("map_matrices")
  Assert.equal(e.symbol, "NARC_fielddata_mapmatrix_map_matrix")
  Assert.equal(e.narcId, 41)
  Assert.equal(e.path, "a/0/4/1")
  Assert.equal(e.alias, "map_matrices")
  Assert.isTrue(e.required)
end

function T.resolves_by_symbol()
  local e = Hgss.resolve("NARC_msgdata_msg")
  Assert.equal(e.narcId, 27)
  Assert.equal(e.alias, "messages")
  Assert.isTrue(e.required)
end

function T.optional_alias_is_not_required()
  Assert.isFalse(Hgss.resolve("font").required)
end

function T.version_neutral_encounters_selects_heartgold()
  local e = Hgss.resolve("encounters", "heartgold")
  Assert.equal(e.symbol, "NARC_fielddata_encountdata_g_enc_data")
  Assert.equal(e.narcId, 37)
end

function T.version_neutral_encounters_selects_soulsilver()
  local e = Hgss.resolve("encounters", "soulsilver")
  Assert.equal(e.symbol, "NARC_fielddata_encountdata_s_enc_data")
  Assert.equal(e.narcId, 136)
end

function T.version_neutral_encounters_requires_a_version()
  Assert.throws(function() Hgss.resolve("encounters") end)
end

function T.rejects_unknown_alias()
  Assert.throws(function() Hgss.resolve("not_a_real_alias") end)
end

function T.alias_list_is_complete_and_deterministic()
  local list = Hgss.aliasList()
  Assert.equal(#list, 20)
  -- Sorted ascending by narcId.
  for i = 2, #list do
    Assert.isTrue(list[i - 1].narcId < list[i].narcId, "aliasList not sorted by narcId")
  end
  for _, e in ipairs(list) do
    Assert.notNil(e.symbol)
    Assert.notNil(e.alias)
    Assert.notNil(e.path)
    Assert.notNil(e.narcId)
  end
end

return T
