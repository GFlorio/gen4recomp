-- Tests for HgssPermissionGrid: the romdump decoder that turns the raw HGSS
-- permission section (0x800 bytes of 32x32 two-byte records) into semantic
-- records. Byte 0 is the terrain/metatile behavior; byte 1 is a packed
-- movement value whose top bit (0x80) is the hard-block flag and whose low 7
-- bits (0x7F) are a terrain/footstep response id -- NOT a plain collision
-- byte, so values like 4 and 6 are passable surface responses. The split
-- matches pret/pokeheartgold's field movement code, which tests bit 15 of the
-- u16 pair for blocking and masks the low 7 bits for the response. Records
-- are indexed row-major z*32+x, matching the field engine. Nothing outside
-- romdump ever sees the packed byte or the 0x80 bit.

local Assert = require("tests.support.Assert")
local HgssPermissionGrid = require("romdump.src.digest.HgssPermissionGrid")

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

local function decode(records)
  return assert(HgssPermissionGrid.decode(build(records)))
end

function T.addresses_records_row_major()
  -- Distinctive behavior byte at the four corners the layout calls out.
  local g = decode({
    [0] = { 1, 0 }, -- (0,0) -> bytes 0,1
    [31] = { 2, 0 }, -- (31,0) -> bytes 62,63
    [32] = { 3, 0 }, -- (0,1) -> bytes 64,65
    [1023] = { 4, 0 }, -- (31,31) -> last two bytes
  })
  Assert.equal(g.width, 32)
  Assert.equal(g.height, 32)
  Assert.equal(#g.cells, 1024)
  Assert.equal(g.cells[1].behavior, 1)
  Assert.equal(g.cells[32].behavior, 2)
  Assert.equal(g.cells[33].behavior, 3)
  Assert.equal(g.cells[1024].behavior, 4)
end

-- The second byte is not a plain collision flag: bit 0x80 is the hard-block
-- flag and the low 7 bits are a terrain/footstep response id.
function T.splits_permission_byte_into_blocked_and_response()
  local cases = {
    { byte = 0x00, blocked = false, response = 0 },
    { byte = 0x04, blocked = false, response = 4 },
    { byte = 0x06, blocked = false, response = 6 },
    { byte = 0x80, blocked = true, response = 0 },
    { byte = 0x84, blocked = true, response = 4 },
    { byte = 0x86, blocked = true, response = 6 },
  }
  for _, c in ipairs(cases) do
    local g = decode({ [0] = { 0x12, c.byte } })
    local cell = g.cells[1]
    Assert.equal(cell.blocked, c.blocked)
    Assert.equal(cell.terrainResponseId, c.response)
    Assert.equal(cell.behavior, 0x12)
  end
end

function T.used_value_sets_are_sorted_and_distinct()
  local g = decode({
    [0] = { 3, 0x86 },
    [1] = { 1, 0x00 },
    [2] = { 3, 0x86 },
  })
  Assert.deepEqual(g.usedBehaviorValues, { 0, 1, 3 })
  Assert.deepEqual(g.usedPermissionValues, { 0, 0x86 })
end

function T.rejects_wrong_size()
  local g, err = HgssPermissionGrid.decode(string.rep("\0", 0x800 - 2))
  Assert.isNil(g)
  Assert.notNil(err)
  Assert.equal(assert(err).code, "PERMISSION_BAD_SIZE")
end

return { metadata = { layer = "unit" }, tests = T }
