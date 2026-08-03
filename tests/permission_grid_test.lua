local Assert = require("tests.support.Assert")
local PermissionGrid = require("src.data.PermissionGrid")

local T = {}

-- Build a 0x800 permission section. records maps zero-based
-- index (z*32+x) -> { terrain, collision }; everything else is {0,0}.
local function build(records)
  records = records or {}
  local bytes = {}
  for index = 0, 1023 do
    local rec = records[index] or { 0, 0 }
    bytes[#bytes + 1] = string.char(rec[1] % 256, rec[2] % 256)
  end
  return table.concat(bytes)
end

function T.addresses_records_row_major()
  -- Distinctive terrain/collision at the four corners the spec calls out.
  local g = assert(PermissionGrid.decode(build({
    [0] = { 1, 0 },      -- (0,0) -> bytes 0,1
    [31] = { 2, 0 },     -- (31,0) -> bytes 62,63
    [32] = { 3, 0 },     -- (0,1) -> bytes 64,65
    [1023] = { 4, 0 },   -- (31,31) -> last two bytes
  })))
  Assert.equal(g:get(0, 0).terrain, 1)
  Assert.equal(g:get(31, 0).terrain, 2)
  Assert.equal(g:get(0, 1).terrain, 3)
  Assert.equal(g:get(31, 31).terrain, 4)
end

function T.raw_packs_terrain_and_collision()
  local g = assert(PermissionGrid.decode(build({ [0] = { 0x12, 0x80 } })))
  local rec = g:get(0, 0)
  Assert.equal(rec.terrain, 0x12)
  Assert.equal(rec.collision, 0x80)
  Assert.equal(rec.raw, 0x12 + 0x80 * 256)
end

function T.contains_rejects_out_of_range_without_wrapping()
  local g = assert(PermissionGrid.decode(build()))
  Assert.isTrue(g:contains(0, 0))
  Assert.isTrue(g:contains(31, 31))
  Assert.isFalse(g:contains(32, 0))
  Assert.isFalse(g:contains(0, 32))
  Assert.isFalse(g:contains(-1, 0))
  Assert.throws(function() g:get(32, 0) end)
end

function T.collision_policy_blocks_impassable_flag()
  local g = assert(PermissionGrid.decode(build({
    [0] = { 0, 0x00 },
    [1] = { 0, 0x80 },
    [2] = { 0, 0x81 },
    [3] = { 0, 0xFF },
  })))
  Assert.isFalse((g:isBlocked(0, 0)))
  Assert.isTrue((g:isBlocked(1, 0)))
  Assert.isTrue((g:isBlocked(2, 0)))
  Assert.isTrue((g:isBlocked(3, 0)))
end

function T.unknown_nonzero_collision_reports_raw_value()
  local g = assert(PermissionGrid.decode(build({ [0] = { 0, 0x05 } })))
  local blocked, reason = g:isBlocked(0, 0)
  Assert.isTrue(blocked)
  Assert.isTrue(reason:find("5") ~= nil, "reason should report the raw value, got " .. reason)
  -- Non-strict policy leaves the unknown value passable but still reported.
  local blockedLoose, reasonLoose = g:isBlocked(0, 0, { strict = false })
  Assert.isFalse(blockedLoose)
  Assert.notNil(reasonLoose)
end

function T.used_value_sets_are_sorted_and_distinct()
  local g = assert(PermissionGrid.decode(build({
    [0] = { 3, 0x80 },
    [1] = { 1, 0x00 },
    [2] = { 3, 0x80 },
  })))
  Assert.deepEqual(g:usedTerrainValues(), { 0, 1, 3 })
  Assert.deepEqual(g:usedCollisionValues(), { 0, 0x80 })
end

function T.rejects_wrong_size()
  local g, err = PermissionGrid.decode(string.rep("\0", 0x800 - 2))
  Assert.isNil(g)
  Assert.equal(err.code, "PERMISSION_BAD_SIZE")
end

return T
