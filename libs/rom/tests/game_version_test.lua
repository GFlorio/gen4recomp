local Assert = require("tests.support.Assert")
local GameVersion = require("libs.rom.src.GameVersion")

local HG_SHA1 = "4fcded0e2713dc03929845de631d0932ea2b5a37"
local SS_SHA1 = "f8dc38ea20c17541a43b58c5e6d18c1732c7e582"

local T = {}

function T.forSha1_resolves_both_versions()
  Assert.equal(GameVersion.forSha1(HG_SHA1).id, "heartgold")
  Assert.equal(GameVersion.forSha1(SS_SHA1).id, "soulsilver")
end

function T.forSha1_is_case_insensitive()
  Assert.equal(GameVersion.forSha1(HG_SHA1:upper()).id, "heartgold")
end

function T.forSha1_rejects_unknown_hash()
  Assert.isNil(GameVersion.forSha1("0000000000000000000000000000000000000000"))
end

function T.forGameCode_resolves_both_versions()
  Assert.equal(GameVersion.forGameCode("IPKE").id, "heartgold")
  Assert.equal(GameVersion.forGameCode("IPGE").id, "soulsilver")
end

function T.forGameCode_rejects_unknown_code()
  Assert.isNil(GameVersion.forGameCode("XXXX"))
end

function T.info_returns_full_record()
  local hg = GameVersion.info("heartgold")
  Assert.equal(hg.displayName, "Pokemon HeartGold")
  Assert.equal(hg.gameCode, "IPKE")
  Assert.equal(hg.sha1, HG_SHA1)
  Assert.equal(hg.expectedSize, 134217728)
end

function T.info_rejects_unknown_version()
  Assert.isNil(GameVersion.info("gold"))
end

function T.set_and_get_round_trip()
  GameVersion.set("soulsilver")
  Assert.equal(GameVersion.get(), "soulsilver")
  Assert.equal(GameVersion.info().id, "soulsilver")
end

function T.set_rejects_unknown_version()
  Assert.throws(function()
    GameVersion.set("crystal")
  end)
end

function T.cache_prefixes_do_not_collide()
  Assert.equal(GameVersion.cachePrefix("heartgold"), "heartgold/")
  Assert.equal(GameVersion.cachePrefix("soulsilver"), "soulsilver/")
  Assert.isTrue(GameVersion.cachePrefix("heartgold") ~= GameVersion.cachePrefix("soulsilver"))
end

function T.order_lists_both_versions()
  Assert.deepEqual(GameVersion.ORDER, { "heartgold", "soulsilver" })
end

return T
