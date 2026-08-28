-- CollisionGrid maps local<->global tile coordinates around a cell origin and
-- reports blocking straight from the decoded project-owned collision asset.
-- It knows nothing about HGSS permission packing: blocked is a semantic cell
-- flag, and behavior/terrainResponseId are opaque cell fields.

local Assert = require("tests.support.Assert")
local CollisionFixture = require("tests.support.CollisionFixture")
local CollisionGrid = require("libs.engine.src.CollisionGrid")

return {
  tests = {
    ["origin 0,0 makes local == global"] = function()
      local c = CollisionGrid.new(CollisionFixture.grid32(), {})
      local gx, gz = c:localToGlobal(4, 14)
      Assert.equal(gx, 4)
      Assert.equal(gz, 14)
      local lx, lz = c:globalToLocal(4, 14)
      Assert.equal(lx, 4)
      Assert.equal(lz, 14)
    end,

    ["applies a nonzero cell origin both ways"] = function()
      local c = CollisionGrid.new(CollisionFixture.grid32(), { worldOriginX = 672, worldOriginZ = 384 })
      local lx, lz = c:globalToLocal(684, 393)
      Assert.equal(lx, 12)
      Assert.equal(lz, 9)
      local gx, gz = c:localToGlobal(12, 9)
      Assert.equal(gx, 684)
      Assert.equal(gz, 393)
    end,

    ["blocks only flagged cells, local and global"] = function()
      local c =
        CollisionGrid.new(CollisionFixture.grid32({ { x = 1, z = 2 } }), { worldOriginX = 100, worldOriginZ = 200 })
      Assert.isTrue(c:isBlockedLocal(1, 2))
      Assert.isFalse(c:isBlockedLocal(3, 2))
      Assert.isFalse(c:isBlockedLocal(5, 2))
      Assert.isTrue(c:isBlockedGlobal(101, 202)) -- same tile via global
      Assert.isFalse(c:isBlockedGlobal(103, 202))
    end,

    ["exposes the cell record for HUD"] = function()
      local cells = {}
      for z = 0, 31 do
        for x = 0, 31 do
          cells[z * 32 + x + 1] = { behavior = 7, terrainResponseId = 6, blocked = false }
        end
      end
      cells[5 * 32 + 5 + 1] = { behavior = 7, terrainResponseId = 6, blocked = true }
      local c = CollisionGrid.new({ width = 32, height = 32, cells = cells }, {})
      local rec = c:getLocal(5, 5)
      Assert.isTrue(rec.blocked)
      Assert.equal(rec.terrainResponseId, 6)
      Assert.equal(rec.behavior, 7)
      Assert.isFalse(c:getLocal(0, 0).blocked)
    end,

    ["contains rejects out-of-range and fractional coordinates"] = function()
      local c = CollisionGrid.new(CollisionFixture.grid32(), {})
      Assert.isTrue(c:containsLocal(0, 0))
      Assert.isTrue(c:containsLocal(31, 31))
      Assert.isFalse(c:containsLocal(32, 0))
      Assert.isFalse(c:containsLocal(0, 32))
      Assert.isFalse(c:containsLocal(-1, 0))
      local fractionalCoordinate = 0.5 --[[@as integer]]
      Assert.isFalse(c:containsLocal(fractionalCoordinate, 0))
      Assert.throws(function()
        c:isBlockedLocal(32, 0)
      end)
      Assert.throws(function()
        c:isBlockedGlobal(32, 0)
      end)
    end,
  },
}
