-- FieldGrid centres the 32-tile permission cell on the map model origin: tile
-- centres run from -15.5 to +15.5, one unit per tile.

local Assert = require("tests.support.Assert")
local FieldGrid = require("libs.hgss.src.world.FieldGrid")

return {
  tests = {
    ["tile (0,0) centre is the cell's north-west corner"] = function()
      local x, z = FieldGrid.tileCenterToWorld(0, 0)
      Assert.equal(x, -15.5)
      Assert.equal(z, -15.5)
    end,

    ["tile (31,31) centre is the cell's south-east corner"] = function()
      local x, z = FieldGrid.tileCenterToWorld(31, 31)
      Assert.equal(x, 15.5)
      Assert.equal(z, 15.5)
    end,

    ["adjacent tiles are one world unit apart"] = function()
      local x0 = FieldGrid.tileCenterToWorld(4, 14)
      local x1 = FieldGrid.tileCenterToWorld(5, 14)
      Assert.equal(x1 - x0, 1)
      local _, z0 = FieldGrid.tileCenterToWorld(4, 14)
      local _, z1 = FieldGrid.tileCenterToWorld(4, 15)
      Assert.equal(z1 - z0, 1)
    end,
  },
}
