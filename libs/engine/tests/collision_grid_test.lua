-- CollisionGrid maps local<->global tile coordinates around a cell origin and
-- reports blocking straight through the permission grid's hard-block bit.

local Assert = require("tests.support.Assert")
local PermissionGrid = require("libs.assets.src.PermissionGrid")
local CollisionGrid = require("libs.engine.src.CollisionGrid")

-- 0x800 permission section; set tile (lx,lz) byte 1 to `perm`.
local function gridWith(entries)
  local bytes = {}
  for i = 1, 0x800 do
    bytes[i] = "\0"
  end
  for _, e in ipairs(entries) do
    local index = e.z * 32 + e.x
    bytes[index * 2 + 2] = string.char(e.perm) -- byte 1 (permission)
  end
  return assert(PermissionGrid.decode(table.concat(bytes)))
end

return {
  ["origin 0,0 makes local == global"] = function()
    local c = CollisionGrid.new(gridWith({}), {})
    local gx, gz = c:localToGlobal(4, 14)
    Assert.equal(gx, 4)
    Assert.equal(gz, 14)
    local lx, lz = c:globalToLocal(4, 14)
    Assert.equal(lx, 4)
    Assert.equal(lz, 14)
  end,

  ["applies a nonzero cell origin both ways"] = function()
    local c = CollisionGrid.new(gridWith({}), { worldOriginX = 672, worldOriginZ = 384 })
    local lx, lz = c:globalToLocal(684, 393)
    Assert.equal(lx, 12)
    Assert.equal(lz, 9)
    local gx, gz = c:localToGlobal(12, 9)
    Assert.equal(gx, 684)
    Assert.equal(gz, 393)
  end,

  ["blocks only the 0x80 bit, local and global"] = function()
    local c = CollisionGrid.new(
      gridWith({
        { x = 1, z = 2, perm = 0x80 },
        { x = 3, z = 2, perm = 0x06 },
      }),
      { worldOriginX = 100, worldOriginZ = 200 }
    )
    Assert.isTrue(c:isBlockedLocal(1, 2))
    Assert.isFalse(c:isBlockedLocal(3, 2)) -- surface response 6, passable
    Assert.isTrue(c:isBlockedGlobal(101, 202)) -- same tile via global
    Assert.isFalse(c:isBlockedGlobal(103, 202))
  end,

  ["exposes the permission record for HUD"] = function()
    local c = CollisionGrid.new(gridWith({ { x = 5, z = 5, perm = 0x86 } }), {})
    local rec = c:getLocal(5, 5)
    Assert.isTrue(rec.hardBlocked)
    Assert.equal(rec.terrainResponseId, 6)
  end,
}
