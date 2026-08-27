local Assert = require("tests.support.Assert")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function flatMap()
  return {
    mapId = 61,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
end

function T.script_position_must_keep_field_local_world_surface_coherent()
  local map = flatMap()
  local player = FieldPlayer.new({ currentMap = map, fieldX = 2, fieldZ = 3, surfaceId = 0, facing = "south" })

  player:setScriptPosition({ fieldX = 5, fieldZ = 5 })

  local status = player:status()
  local expectedWorld = FieldCoordinates.fieldToWorld(map, 5, 5, 0)
  Assert.equal(status.fieldX, 5, "fieldX was set to destination")
  Assert.equal(status.localX, 5, "localX must track fieldX")
  Assert.equal(status.surfaceId, 0, "surface must remain walkable")
  Assert.near(player.worldX, expectedWorld.x, 1e-9, "worldX must match field-to-world")
  Assert.near(player.worldZ, expectedWorld.z, 1e-9, "worldZ must match field-to-world")
  Assert.near(player:renderPosition(0).x, player.worldX, 1e-9)
  Assert.near(player:renderPosition(1).x, player.worldX, 1e-9)
  Assert.near(player:renderPosition(0).z, player.worldZ, 1e-9)

  -- setScriptPosition must resolve terrain through the surface resolver and
  -- collapse interpolation, so no stale previousWorld leaks.
  Assert.near(player.previousWorldX, player.worldX, 1e-9)
  Assert.near(player.previousWorldZ, player.worldZ, 1e-9)
end

return { tests = T }
