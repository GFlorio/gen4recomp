-- Route-search contract for the acceptance movement helper: every planned
-- edge must come from the same production step resolution `FieldPlayer` uses
-- (collision, terrain, live actor occupancy), never a second collision-only
-- model. A tiny flat map fixture keeps this a fast component test.

local Assert = require("tests.support.Assert")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldMovement = require("tests.acceptance.support.FieldMovement")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local FLAT_PLATE = {
  id = 0,
  minX = 0,
  minZ = 0,
  maxX = 32,
  maxZ = 32,
  normal = { x = 0, y = 1, z = 0 },
  distance = 0,
  slopeClass = "flat",
}

---@param blocked table<string, boolean>|nil local "x:z" keys the collision grid rejects
---@param warps table[]|nil global field warp records
local function flatMap(blocked, warps)
  return {
    mapId = 60,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function(_, x, z)
        return blocked ~= nil and blocked[x .. ":" .. z] or false
      end,
    },
    terrain = TerrainSurface.new({ plates = { FLAT_PLATE } }),
    fieldData = { events = { warps = warps or {}, coordinates = {} } },
  }
end

---@param map table
---@param x integer
---@param z integer
---@param occupancy fun(candidate: FieldOccupancyCandidate): string|nil
local function gameAt(map, x, z, occupancy)
  return {
    runtime = {
      player = FieldPlayer.new({ currentMap = map, fieldX = x, fieldZ = z, surfaceId = 0, occupancy = occupancy }),
      eventState = {
        getVar = function()
          return 0
        end,
      },
    },
  }
end

function T.route_prefers_an_open_path_and_never_enters_an_occupied_tile()
  local map = flatMap()
  local occupied = { ["5:0"] = "npc-1" }
  local occupancy = function(candidate)
    return occupied[candidate.fieldX .. ":" .. candidate.fieldZ]
  end
  local game = gameAt(map, 4, 0, occupancy)

  local route = assert(FieldMovement.route(game, { fieldX = 6, fieldZ = 0 }), "a route around the occupant must exist")
  for _, step in ipairs(route) do
    Assert.isNil(occupied[step.fieldX .. ":" .. step.fieldZ], "the planned route must never enter an occupied tile")
  end
  Assert.equal(route[#route].fieldX, 6)
  Assert.equal(route[#route].fieldZ, 0)
end

function T.route_reports_no_path_when_occupancy_seals_every_approach()
  local map = flatMap({
    -- Wall off the target on three sides so the only entrance is the
    -- occupied tile below it.
    ["6:1"] = true,
    ["7:0"] = true,
    ["5:1"] = true,
  })
  local occupied = { ["6:-1"] = "npc-1" }
  local occupancy = function(candidate)
    return occupied[candidate.fieldX .. ":" .. candidate.fieldZ]
  end
  local game = gameAt(map, 6, 0, occupancy)

  local route = FieldMovement.route(game, { fieldX = 6, fieldZ = -1 })
  Assert.isNil(route, "no production movement route exists when occupancy seals the only approach")
end

function T.route_only_enters_a_warp_tile_as_the_final_target()
  local warps = { { x = 5, z = 0 } }
  local map = flatMap(nil, warps)
  local game = gameAt(map, 4, 0, function()
    return nil
  end)

  -- The warp tile sits directly on the shortest path to (6, 0); the route
  -- must detour around it rather than pass through.
  local throughRoute = assert(FieldMovement.route(game, { fieldX = 6, fieldZ = 0 }))
  for _, step in ipairs(throughRoute) do
    Assert.isFalse(
      step.fieldX == 5 and step.fieldZ == 0,
      "a route to a target beyond the warp must not pass through it"
    )
  end

  -- The warp tile itself is a valid final target.
  local ontoWarp = assert(FieldMovement.route(game, { fieldX = 5, fieldZ = 0 }))
  local last = ontoWarp[#ontoWarp]
  Assert.equal(last.fieldX, 5)
  Assert.equal(last.fieldZ, 0)
end

return { tests = T }
