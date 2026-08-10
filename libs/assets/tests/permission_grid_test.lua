local Assert = require("tests.support.Assert")
local PermissionGrid = require("libs.assets.src.PermissionGrid")

local T = {}

-- Build a 0x800 permission section. records maps zero-based
-- index (z*32+x) -> { behavior, permission }; everything else is {0,0}.
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
  -- Distinctive behavior byte at the four corners the layout calls out.
  local g = assert(PermissionGrid.decode(build({
    [0] = { 1, 0 }, -- (0,0) -> bytes 0,1
    [31] = { 2, 0 }, -- (31,0) -> bytes 62,63
    [32] = { 3, 0 }, -- (0,1) -> bytes 64,65
    [1023] = { 4, 0 }, -- (31,31) -> last two bytes
  })))
  Assert.equal(g:get(0, 0).behavior, 1)
  Assert.equal(g:get(31, 0).behavior, 2)
  Assert.equal(g:get(0, 1).behavior, 3)
  Assert.equal(g:get(31, 31).behavior, 4)
end

-- The second byte is not a plain collision flag: bit 0x80 is the hard-block
-- flag and the low 7 bits are a terrain/footstep response id.
function T.splits_permission_byte_into_hard_block_and_response()
  local cases = {
    { byte = 0x00, blocked = false, response = 0 },
    { byte = 0x04, blocked = false, response = 4 },
    { byte = 0x06, blocked = false, response = 6 },
    { byte = 0x80, blocked = true, response = 0 },
    { byte = 0x84, blocked = true, response = 4 },
    { byte = 0x86, blocked = true, response = 6 },
  }
  for _, c in ipairs(cases) do
    local g = assert(PermissionGrid.decode(build({ [0] = { 0x12, c.byte } })))
    local rec = g:get(0, 0)
    Assert.equal(rec.permissionRaw, c.byte)
    Assert.equal(rec.hardBlocked, c.blocked)
    Assert.equal(rec.terrainResponseId, c.response)
    Assert.equal(rec.behavior, 0x12)
    Assert.equal(rec.raw, 0x12 + c.byte * 256)
    -- isBlocked reflects only the hard-block bit; 4 and 6 are passable.
    Assert.equal(g:isBlocked(0, 0), c.blocked)
  end
end

function T.contains_rejects_out_of_range_without_wrapping()
  local g = assert(PermissionGrid.decode(build()))
  Assert.isTrue(g:contains(0, 0))
  Assert.isTrue(g:contains(31, 31))
  Assert.isFalse(g:contains(32, 0))
  Assert.isFalse(g:contains(0, 32))
  Assert.isFalse(g:contains(-1, 0))
  Assert.throws(function()
    g:get(32, 0)
  end)
end

-- Grid cells are finite integer indices: a fractional in-range coordinate
-- would otherwise read the shifted neighbouring record.
function T.contains_and_get_reject_fractional_and_nonfinite_coordinates()
  local g = assert(PermissionGrid.decode(build({ [0] = { 1, 0 } })))
  Assert.isFalse(g:contains(0.5, 0))
  Assert.isFalse(g:contains(0, 0.5))
  Assert.isFalse(g:contains(0 / 0, 0))
  Assert.isFalse(g:contains(math.huge, 0))
  Assert.isFalse(g:contains(0, -math.huge))
  Assert.throws(function()
    g:get(0.5, 0)
  end)
  Assert.throws(function()
    g:isBlocked(0, 1.5)
  end)
end

function T.used_value_sets_are_sorted_and_distinct()
  local g = assert(PermissionGrid.decode(build({
    [0] = { 3, 0x86 },
    [1] = { 1, 0x00 },
    [2] = { 3, 0x86 },
  })))
  Assert.deepEqual(g:usedBehaviorValues(), { 0, 1, 3 })
  Assert.deepEqual(g:usedPermissionValues(), { 0, 0x86 })
end

function T.rejects_wrong_size()
  local g, err = PermissionGrid.decode(string.rep("\0", 0x800 - 2))
  Assert.isNil(g)
  Assert.equal(err.code, "PERMISSION_BAD_SIZE")
end

return T
