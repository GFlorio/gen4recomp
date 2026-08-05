-- DebugPlayer: a diagnostic field actor that steps one tile per directional
-- input over a CollisionGrid, stays inside the 32x32 cell, is stopped only by
-- the permission grid's hard-block bit, and validates its spawn (falling back to
-- the nearest passable tile deterministically).

local Assert = require("tests.support.Assert")
local PermissionGrid = require("libs.assets.src.PermissionGrid")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local DebugPlayer = require("libs.engine.src.DebugPlayer")

-- 0x800 permission section; `blocked` is a list of {x,z} tiles set to 0x80 and
-- `responses` a list of {x,z,byte} tiles set to a passable response byte.
local function collision(blocked, responses, origin)
  local bytes = {}
  for i = 1, 0x800 do bytes[i] = "\0" end
  for _, e in ipairs(blocked or {}) do
    bytes[(e[2] * 32 + e[1]) * 2 + 2] = string.char(0x80)
  end
  for _, e in ipairs(responses or {}) do
    bytes[(e[2] * 32 + e[1]) * 2 + 2] = string.char(e[3])
  end
  local grid = assert(PermissionGrid.decode(table.concat(bytes)))
  return CollisionGrid.new(grid, origin or {})
end

return {
  ["spawns at the requested passable tile"] = function()
    local p = DebugPlayer.new(collision(), { x = 4, z = 13, facing = "north" })
    local s = p:status()
    Assert.equal(s.localX, 4)
    Assert.equal(s.localZ, 13)
    Assert.equal(s.facing, "north")
    Assert.isFalse(s.spawnFallback)
  end,

  ["steps one tile per input and updates facing"] = function()
    local p = DebugPlayer.new(collision(), { x = 4, z = 13 })
    Assert.isTrue(p:tryStep("north"))
    Assert.equal(p:status().localZ, 12) -- north decreases z (+Z is south)
    Assert.equal(p:status().facing, "north")
    Assert.isTrue(p:tryStep("east"))
    Assert.equal(p:status().localX, 5)
  end,

  ["is stopped by a hard-blocked tile but still turns"] = function()
    local p = DebugPlayer.new(collision({ { 4, 12 } }), { x = 4, z = 13 })
    Assert.isFalse(p:tryStep("north"))
    Assert.equal(p:status().localZ, 13) -- did not move
    Assert.equal(p:status().facing, "north") -- but faces the wall
  end,

  ["surface responses 4 and 6 are passable"] = function()
    local p = DebugPlayer.new(collision(nil, { { 4, 12, 6 }, { 4, 11, 4 } }), { x = 4, z = 13 })
    Assert.isTrue(p:tryStep("north"))
    Assert.isTrue(p:tryStep("north"))
    Assert.equal(p:status().localZ, 11)
  end,

  ["will not leave the 32x32 cell"] = function()
    local p = DebugPlayer.new(collision(), { x = 0, z = 0 })
    Assert.isFalse(p:tryStep("west"))  -- x would be -1
    Assert.isFalse(p:tryStep("north")) -- z would be -1
    Assert.equal(p:status().localX, 0)
    Assert.equal(p:status().localZ, 0)
  end,

  ["falls back to the nearest passable tile when the spawn is blocked"] = function()
    -- Block the requested spawn (4,13) and its immediate west/north; the search
    -- must deterministically land on a nearby passable tile and flag it.
    local p = DebugPlayer.new(collision({ { 4, 13 } }), { x = 4, z = 13 })
    local s = p:status()
    Assert.isTrue(s.spawnFallback)
    Assert.isFalse(p.collision:isBlockedLocal(s.localX, s.localZ))
    Assert.isTrue(math.abs(s.localX - 4) + math.abs(s.localZ - 13) <= 2)
  end,

  ["reports the permission record and global coords under the player"] = function()
    local p = DebugPlayer.new(
      collision(nil, { { 5, 5, 0x06 } }, { worldOriginX = 672, worldOriginZ = 384 }),
      { x = 5, z = 5 })
    local s = p:status()
    Assert.equal(s.behavior, 0)
    Assert.equal(s.permissionRaw, 6)
    Assert.isFalse(s.hardBlocked)
    Assert.equal(s.terrainResponseId, 6)
    Assert.equal(s.globalX, 677)
    Assert.equal(s.globalZ, 389)
  end,
}
