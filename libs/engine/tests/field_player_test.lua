-- FieldPlayer tests freeze eight-tick commits, collision, buffering, and
-- continuous height sampling without depending on LÖVE or imported data.

local Assert = require("tests.support.Assert")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}
local ROOT_HALF = math.sqrt(0.5)

local function near(actual, expected)
  Assert.isTrue(math.abs(actual - expected) <= 1e-9, string.format("expected %.9f, got %.9f", expected, actual))
end

local function runtimeMap(blocked)
  local plates = {
    {
      id = 0,
      minX = 0,
      minZ = 0,
      maxX = 1,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 0,
      slopeClass = "flat",
    },
    {
      id = 1,
      minX = 1,
      minZ = 0,
      maxX = 3,
      maxZ = 32,
      normal = { x = -ROOT_HALF, y = ROOT_HALF, z = 0 },
      distance = -ROOT_HALF,
      slopeClass = "ramp-east",
    },
    {
      id = 2,
      minX = 3,
      minZ = 0,
      maxX = 32,
      maxZ = 32,
      normal = { x = 0, y = 1, z = 0 },
      distance = 2,
      slopeClass = "flat",
    },
  }
  return {
    mapId = 60,
    coordinateOrigin = { x = 0, z = 0 },
    permissions = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function(_, x, z)
        return blocked and blocked[x .. ":" .. z] or false
      end,
      getLocal = function()
        return { hardBlocked = false }
      end,
    },
    terrain = TerrainSurface.new({ plates = plates }),
  }
end

local function player(map, x, z, surfaceId)
  return FieldPlayer.new({ currentMap = map, fieldX = x, fieldZ = z, surfaceId = surfaceId, facing = "south" })
end

local function tick(p, held, pressed)
  p:updateFixed({ heldDirection = held, pressedDirection = pressed })
end

function T.accepted_step_commits_on_exactly_tick_eight()
  local p = player(runtimeMap(), 0, 4, 0)
  for index = 1, 7 do
    tick(p, "east", index == 1 and "east" or nil)
    Assert.equal(p.fieldX, 0)
    Assert.equal(p.motion, "walking")
  end
  tick(p, "east")
  Assert.equal(p.fieldX, 1)
  Assert.equal(p.surfaceId, 1)
  Assert.equal(p.motion, "idle")
  near(p.worldY, 0.5)
end

function T.blocked_input_turns_without_moving()
  local p = player(runtimeMap({ ["0:3"] = true }), 0, 4, 0)
  tick(p, "north", "north")
  Assert.equal(p.facing, "north")
  Assert.equal(p.fieldZ, 4)
  Assert.equal(p.motion, "idle")
end

function T.disconnected_height_jump_is_rejected()
  local map = runtimeMap()
  map.terrain.plates[2].distance = 5 * ROOT_HALF
  local p = player(map, 0, 4, 0)
  tick(p, "east", "east")
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.motion, "idle")
end

function T.walking_samples_monotonic_slope_height()
  local p = player(runtimeMap(), 0, 4, 0)
  local heights = {}
  for index = 1, 16 do
    tick(p, "east", index == 1 and "east" or nil)
    heights[#heights + 1] = p.worldY
  end
  for index = 2, #heights do
    Assert.isTrue(heights[index] >= heights[index - 1], "height decreased on ascent")
  end
  Assert.equal(p.fieldX, 2)
  Assert.equal(p.surfaceId, 1)
  near(p.worldY, 1.5)
end

function T.latest_pressed_direction_buffers_during_a_step()
  local p = player(runtimeMap(), 0, 4, 0)
  tick(p, "east", "east")
  for _ = 2, 4 do
    tick(p, "east")
  end
  tick(p, "south", "south")
  for _ = 6, 8 do
    tick(p, "south")
  end
  Assert.equal(p.fieldX, 1)
  Assert.equal(p.fieldZ, 4)
  tick(p, "south")
  Assert.equal(p.motion, "walking")
  for _ = 2, 8 do
    tick(p, "south")
  end
  Assert.equal(p.fieldZ, 5)
end

function T.render_position_interpolates_previous_and_current_fixed_points()
  local p = player(runtimeMap(), 0, 4, 0)
  tick(p, "east", "east")
  local point = p:renderPosition(0.5)
  Assert.equal(point.x, p.previousWorldX + (p.worldX - p.previousWorldX) * 0.5)
  Assert.equal(point.y, p.previousWorldY + (p.worldY - p.previousWorldY) * 0.5)
end

-- Occupancy is an injected predicate so FieldPlayer never imports the actor
-- manager; it only needs truthy/nil answers per destination cell.
local function occupyingPlayer(map, x, z, surfaceId, occupantCells)
  local p = FieldPlayer.new({
    currentMap = map,
    fieldX = x,
    fieldZ = z,
    surfaceId = surfaceId,
    facing = "south",
    occupancy = function(cellX, cellZ, cellSurface)
      local key = cellX .. ":" .. cellZ .. ":" .. cellSurface
      return occupantCells[key] or nil
    end,
  })
  return p
end

function T.actor_on_the_resolved_destination_surface_blocks_the_step()
  local p = occupyingPlayer(runtimeMap(), 0, 4, 0, { ["1:4:1"] = "map:61:object:0" })
  tick(p, "east", "east")
  Assert.equal(p.facing, "east")
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.motion, "idle")
end

function T.actor_on_a_different_surface_does_not_block_the_same_cell()
  -- The east step resolves onto surface 1; an occupant on surface 0 at the
  -- same cell must not block it.
  local p = occupyingPlayer(runtimeMap(), 0, 4, 0, { ["1:4:0"] = "map:61:object:0" })
  tick(p, "east", "east")
  Assert.equal(p.motion, "walking")
  for _ = 2, 8 do
    tick(p, "east")
  end
  Assert.equal(p.fieldX, 1)
  Assert.equal(p.surfaceId, 1)
end

function T.terrain_rejection_takes_precedence_over_occupancy()
  -- A disconnected height jump fails surface resolution before occupancy is
  -- ever consulted.
  local map = runtimeMap()
  map.terrain.plates[2].distance = 5 * ROOT_HALF
  local p = occupyingPlayer(map, 0, 4, 0, { ["1:4:1"] = "map:61:object:0" })
  tick(p, "east", "east")
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.motion, "idle")
end

function T.occupancy_blocks_only_the_cell_it_names()
  local p = occupyingPlayer(runtimeMap(), 0, 4, 0, { ["3:4:2"] = "map:61:object:0" })
  tick(p, "east", "east")
  Assert.equal(p.motion, "walking")
  for _ = 2, 16 do
    tick(p, "east")
  end
  Assert.equal(p.fieldX, 2)
end

return T
