-- A diagnostic field actor -- not the HGSS player-character system. It occupies
-- one local tile of a CollisionGrid, steps exactly one tile per accepted
-- directional input, never leaves the 32x32 cell, and is blocked only by the
-- permission grid's hard-block bit (surface responses like 4 and 6 stay
-- passable). Height is flat (BDHC is deferred); the y field is a tunable base.
-- The spawn is validated: if the requested tile is out of bounds or hard-blocked
-- the constructor searches outward in a deterministic ring order for the nearest
-- passable tile and records the fallback. Pure domain module (no love); movement
-- and coordinate policy live in CollisionGrid / PermissionGrid.

local DebugPlayer = {}
DebugPlayer.__index = DebugPlayer

DebugPlayer.BASE_Y = 0

-- +Z is south, so north decreases z. No diagonals.
local DELTAS = {
  north = { 0, -1 },
  south = { 0, 1 },
  west = { -1, 0 },
  east = { 1, 0 },
}

local SEARCH_RADIUS = 4

local function passable(collision, x, z)
  return collision:containsLocal(x, z) and not collision:isBlockedLocal(x, z)
end

-- Nearest passable tile to (x,z), scanning expanding Chebyshev rings in a fixed
-- (dz then dx) order so the fallback is deterministic. Returns nil past radius.
local function nearestPassable(collision, x, z)
  for r = 0, SEARCH_RADIUS do
    for dz = -r, r do
      for dx = -r, r do
        if math.max(math.abs(dx), math.abs(dz)) == r and passable(collision, x + dx, z + dz) then
          return x + dx, z + dz
        end
      end
    end
  end
  return nil
end

function DebugPlayer.new(collision, spawn)
  assert(collision, "DebugPlayer.new requires a CollisionGrid")
  spawn = spawn or {}
  local wantX, wantZ = spawn.x or 0, spawn.z or 0
  local x, z = wantX, wantZ
  local fallback = false
  if not passable(collision, x, z) then
    x, z = nearestPassable(collision, wantX, wantZ)
    assert(x, "no passable spawn near (" .. wantX .. ", " .. wantZ .. ")")
    fallback = true
  end
  return setmetatable({
    collision = collision,
    localX = x,
    localZ = z,
    y = DebugPlayer.BASE_Y,
    facing = spawn.facing or "south",
    spawnFallback = fallback,
    requestedSpawn = { x = wantX, z = wantZ },
  }, DebugPlayer)
end

-- Face `direction` and, if the destination tile is in bounds and not hard-
-- blocked, step onto it. Returns whether the step was taken.
function DebugPlayer:tryStep(direction)
  local d = DELTAS[direction]
  assert(d, "unknown direction " .. tostring(direction))
  self.facing = direction
  local nx, nz = self.localX + d[1], self.localZ + d[2]
  if not passable(self.collision, nx, nz) then return false end
  self.localX, self.localZ = nx, nz
  return true
end

-- Full readout for the diagnostic HUD: position (local + global), facing, the
-- permission record under the player, and whether the spawn was relocated.
function DebugPlayer:status()
  local rec = self.collision:getLocal(self.localX, self.localZ)
  local gx, gz = self.collision:localToGlobal(self.localX, self.localZ)
  return {
    localX = self.localX,
    localZ = self.localZ,
    globalX = gx,
    globalZ = gz,
    y = self.y,
    facing = self.facing,
    behavior = rec.behavior,
    permissionRaw = rec.permissionRaw,
    hardBlocked = rec.hardBlocked,
    terrainResponseId = rec.terrainResponseId,
    spawnFallback = self.spawnFallback,
  }
end

return DebugPlayer
