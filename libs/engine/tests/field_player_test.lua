-- FieldPlayer tests freeze eight-tick commits, collision, buffering, and
-- continuous height sampling without depending on LÖVE or imported data.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local ROOT_HALF = math.sqrt(0.5)

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

local function near(actual, expected)
  Assert.isTrue(math.abs(actual - expected) <= 1e-9, string.format("expected %.9f, got %.9f", expected, actual))
end

local function runtimeMap(blocked, plates)
  plates = plates
    or {
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
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function(_, x, z)
        return blocked and blocked[x .. ":" .. z] or false
      end,
      getLocal = function()
        return { blocked = false }
      end,
    },
    terrain = TerrainSurface.new({ plates = plates }),
  }
end

local function player(map, x, z, surfaceId)
  return FieldPlayer.new({ currentMap = map, fieldX = x, fieldZ = z, surfaceId = surfaceId, facing = "south" })
end

function T.escalator_motion_is_horizontal_and_does_not_change_height()
  local p = player(runtimeMap(), 0, 4, 0)
  local startX, startY, startZ = p.worldX, p.worldY, p.worldZ
  Assert.isTrue(p:beginTransitionStep("east"))
  for _ = 1, 16 do
    p:updateFixed()
  end
  near(p.worldX, startX + 1)
  Assert.equal(p.worldY, p:renderPosition(0).y)
  near(p.worldZ, startZ)
  Assert.equal(p.fieldX, 1)
end

function T.ladder_source_presentation_preserves_logical_ownership()
  local cases = {
    { method = "beginTransitionLadderExit", facing = "north", y = 2, z = 0 },
    { method = "beginTransitionLadderExit", facing = "south", y = 0.5, z = -1.5 },
    { method = "beginTransitionLadderDownExit", facing = "south", y = -2, z = 0 },
  }
  for _, case in ipairs(cases) do
    local p = player(runtimeMap(), 0, 4, 0)
    local start = {
      fieldX = p.fieldX,
      fieldZ = p.fieldZ,
      localX = p.localX,
      localZ = p.localZ,
      surfaceId = p.surfaceId,
      worldX = p.worldX,
      worldY = p.worldY,
      worldZ = p.worldZ,
    }
    Assert.isTrue(p[case.method](p, case.facing))
    for _ = 1, 8 do
      p:updateFixed({})
    end
    near(p.worldX, start.worldX)
    near(p.worldY, start.worldY + case.y / 2)
    near(p.worldZ, start.worldZ + case.z / 2)
    Assert.equal(p.fieldX, start.fieldX)
    Assert.equal(p.fieldZ, start.fieldZ)
    Assert.equal(p.localX, start.localX)
    Assert.equal(p.localZ, start.localZ)
    Assert.equal(p.surfaceId, start.surfaceId)

    for _ = 1, 8 do
      p:updateFixed({})
    end
    near(p.worldX, start.worldX)
    near(p.worldY, start.worldY + case.y)
    near(p.worldZ, start.worldZ + case.z)
    Assert.equal(p.motion, "idle")
    Assert.equal(p.fieldX, start.fieldX)
    Assert.equal(p.fieldZ, start.fieldZ)
    Assert.equal(p.localX, start.localX)
    Assert.equal(p.localZ, start.localZ)
    Assert.equal(p.surfaceId, start.surfaceId)
  end
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

-- Flat plate at the given height over the given x range; the fixture map
-- covers z 0..32 and keeps collision over 0..31.
local function flatPlate(id, minX, maxX, distance)
  return {
    id = id,
    minX = minX,
    minZ = 0,
    maxX = maxX,
    maxZ = 32,
    normal = { x = 0, y = 1, z = 0 },
    distance = distance,
    slopeClass = "flat",
  }
end

function T.malformed_terrain_failure_is_not_a_blocked_step()
  -- The destination cell is inside permission coverage but no walkable
  -- surface covers it: malformed terrain must propagate, not silently read
  -- as a blocked step.
  local map = runtimeMap(nil, {
    flatPlate(0, 0, 1, 0),
    flatPlate(1, 2, 32, 0),
  })
  local p = player(map, 0, 4, 0)
  throwsCode("TERRAIN_SURFACE_NOT_FOUND", function()
    p:tryStep("east")
  end)
end

function T.ambiguous_terrain_failure_is_not_a_blocked_step()
  -- Two equally-near surfaces cover the destination: ambiguous terrain must
  -- propagate instead of being swallowed as an ordinary collision.
  local map = runtimeMap(nil, {
    flatPlate(0, 0, 1, 0),
    flatPlate(1, 1, 32, 0),
    flatPlate(2, 1, 32, 0),
  })
  local p = player(map, 0, 4, 0)
  throwsCode("TERRAIN_SURFACE_AMBIGUOUS", function()
    p:tryStep("east")
  end)
end

function T.current_disconnected_terrain_failure_is_not_a_blocked_step()
  -- The player's claimed surface does not cover the player's own position:
  -- an inconsistent current terrain state must propagate.
  local map = runtimeMap(nil, {
    flatPlate(0, 2, 32, 0),
    flatPlate(1, 0, 32, 0),
  })
  local p = player(map, 0, 4, 0)
  local err = throwsCode("TERRAIN_SURFACE_DISCONNECTED", function()
    p:tryStep("east")
  end)
  Assert.equal(err.context.kind, "current-inconsistent")
end

function T.out_of_coverage_step_remains_blocked()
  -- Stepping past the coverage edge is the intended edge-of-map contract: a
  -- blocked move, not an error.
  local p = player(runtimeMap(), 31, 4, 2)
  tick(p, "east", "east")
  Assert.equal(p.fieldX, 31)
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

function T.scripted_step_walks_into_a_blocked_permission_cell()
  local p = player(runtimeMap({ ["0:3"] = true }), 0, 4, 0)
  Assert.isTrue(p:scriptedStep("north"))
  Assert.equal(p.facing, "north")
  Assert.equal(p.motion, "walking")
  for _ = 1, 7 do
    tick(p)
    Assert.equal(p.motion, "walking")
  end
  tick(p)
  Assert.equal(p.fieldX, 0)
  Assert.equal(p.fieldZ, 3)
  Assert.equal(p.motion, "idle")
end

function T.scripted_step_ignores_dynamic_occupancy()
  local p = occupyingPlayer(runtimeMap(), 0, 4, 0, { ["1:4:1"] = "map:61:object:0" })
  Assert.isTrue(p:scriptedStep("east"))
  for _ = 1, 8 do
    tick(p)
  end
  Assert.equal(p.fieldX, 1)
  Assert.equal(p.surfaceId, 1)
end

function T.scripted_step_fails_without_a_destination_surface()
  local p = player(runtimeMap(), 0, 4, 0)
  Assert.isFalse(p:scriptedStep("west"))
  Assert.equal(p.motion, "idle")
  Assert.equal(p.fieldX, 0)
end

function T.scripted_step_rejects_an_elevation_jump()
  local map = runtimeMap()
  map.terrain.plates[2].distance = 5 * ROOT_HALF
  local p = player(map, 0, 4, 0)
  Assert.isFalse(p:scriptedStep("east"))
  Assert.equal(p.motion, "idle")
end

function T.scripted_step_requires_an_idle_player()
  local p = player(runtimeMap(), 0, 4, 0)
  tick(p, "east", "east")
  local ok, err = pcall(function()
    p:scriptedStep("east")
  end)
  Assert.isFalse(ok, "a scripted step cannot begin mid-walk")
  Assert.notNil(err)
end

return { tests = T }
