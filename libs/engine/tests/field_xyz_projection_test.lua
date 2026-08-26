-- Physical-origin projection tests keep player, camera, terrain, and transient
-- effect coordinates in one XYZ frame across an altitude recenter.

local Assert = require("tests.support.Assert")
local FieldCamera = require("libs.engine.src.FieldCamera")
local FieldCoverage = require("libs.engine.src.FieldCoverage")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldTerrainEffectController = require("libs.engine.src.FieldTerrainEffectController")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function cellIndex()
  return {
    schema = "g4-field-cell-index-v2",
    matrices = {
      {
        matrixMemberId = 1,
        width = 2,
        height = 1,
        cells = {
          {
            matrixMemberId = 1,
            index = 0,
            x = 0,
            z = 0,
            altitude = 0,
            origin = { x = 0, y = 0, z = 0 },
          },
          {
            matrixMemberId = 1,
            index = 1,
            x = 1,
            z = 0,
            altitude = 1,
            origin = { x = 32, y = 1, z = 0 },
          },
        },
      },
    },
  }
end

local function loadCell(descriptor)
  local key = string.format("%d:%d", descriptor.x, descriptor.z)
  return {
    key = key,
    x = descriptor.x,
    z = descriptor.z,
    origin = descriptor.origin,
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      getLocal = function()
        return { blocked = false }
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
    release = function() end,
  }
end

local function newCoverage()
  return FieldCoverage.new({
    matrixMemberId = 1,
    index = cellIndex(),
    anchorX = 0,
    anchorZ = 0,
    loadCell = loadCell,
  })
end

local function mapFor(coverage, coordinateOriginX)
  return {
    mapId = 60,
    mapSymbol = "projection-test",
    mapSection = "test-section",
    coordinateOrigin = { x = math.floor(coordinateOriginX), z = 0 },
    collision = coverage.region.collision,
    terrain = coverage.region.terrain,
    fieldRegion = coverage.region,
    scene = {},
    fieldData = {},
    cameraType = 4,
    updateAnimated = function() end,
    release = function() end,
  } --[[@as RuntimeFieldMap]]
end

local function cameraProfile()
  return {
    projectionType = "perspective",
    distanceTiles = 10,
    angleXRaw = -8192,
    angleYRaw = 0,
    halfFovRadians = math.rad(15),
    fullVerticalFovRadians = math.rad(30),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }
end

local function copyPoint(point)
  return { x = point.x, y = point.y, z = point.z }
end

local function assertTranslated(actual, before, delta, label)
  Assert.near(actual.x, before.x + delta.x, 1e-9, label .. " x")
  Assert.near(actual.y, before.y + delta.y, 1e-9, label .. " y")
  Assert.near(actual.z, before.z + delta.z, 1e-9, label .. " z")
end

function T.altitude_recenter_translates_player_camera_terrain_and_effect_in_one_xyz_frame()
  local coverage = newCoverage()
  local oldOrigin = coverage:status().physicalOrigin
  local oldMap = mapFor(coverage, oldOrigin.x)
  local sourceSurfaceId = assert(coverage:sourceSurface("1:0", 0))
  local player = FieldPlayer.new({
    currentMap = oldMap,
    fieldX = 33,
    fieldZ = 1,
    surfaceId = sourceSurfaceId,
  })
  local camera = FieldCamera.new(cameraProfile(), { initialTarget = player:renderPosition() })
  camera:updateFixed({ x = player.worldX + 0.25, y = player.worldY + 0.5, z = player.worldZ + 0.75 })
  local effects = FieldTerrainEffectController.new({
    effects = { tall_grass = { model = { animations = { { name = "grass", frameCount = 4 } } } } },
    modelFactory = function()
      local animationPlayer = {
        frameFx = 0,
        isComplete = function()
          return false
        end,
      }
      local instance = {
        play = function()
          return { player = animationPlayer }
        end,
        updateFixed = function() end,
      }
      return instance
    end,
  })
  effects:emit({ kind = "tall_grass", fieldX = 33, fieldZ = 1, worldY = player.worldY, direction = "east" })

  local beforePlayer = { x = player.worldX, y = player.worldY, z = player.worldZ }
  local beforeCamera = {
    sourceTarget = copyPoint(camera.sourceTarget),
    target = copyPoint(camera.target),
    previousTarget = copyPoint(camera.previousTarget),
    eye = copyPoint(camera.eye),
    previousEye = copyPoint(camera.previousEye),
  }
  local beforeSourceY = camera.cameraSourceY
  local beforeAppliedY = camera.cameraAppliedY
  local beforeEffect = effects:drawItems(oldOrigin)[1]
  local beforeTerrainY = coverage.region.terrain:sampleHeight(sourceSurfaceId, 33.5, 1.5)

  coverage:recenter(1, 0)
  local newOrigin = coverage:status().physicalOrigin
  local delta = {
    x = oldOrigin.x - newOrigin.x,
    y = oldOrigin.y - newOrigin.y,
    z = oldOrigin.z - newOrigin.z,
  }
  local newMap = mapFor(coverage, newOrigin.x)
  -- The current boundary accepts only the horizontal frame delta; these
  -- assertions define the full-frame extension that must carry the same XYZ delta.
  player:rebindCoverage(newMap, delta.x, 0, delta.z, "1:0", 0)
  camera:rebase(delta.x, delta.y, delta.z)

  local afterEffect = effects:drawItems(newOrigin)[1]
  local reboundSurfaceId = assert(coverage:sourceSurface("1:0", 0))
  local afterTerrainY = coverage.region.terrain:sampleHeight(reboundSurfaceId, 1.5, 1.5)

  assertTranslated(player:renderPosition(), beforePlayer, delta, "player")
  Assert.equal(player.surfaceId, reboundSurfaceId, "player surface identity must survive composite-id remapping")
  for name, before in pairs(beforeCamera) do
    assertTranslated(camera[name], before, delta, "camera " .. name)
  end
  Assert.near(camera.cameraSourceY, beforeSourceY + delta.y, 1e-9, "camera source Y")
  Assert.near(camera.cameraAppliedY, beforeAppliedY + delta.y, 1e-9, "camera applied Y")
  Assert.near(afterTerrainY, beforeTerrainY + delta.y, 1e-9, "terrain Y")
  Assert.near(afterEffect.localX, beforeEffect.localX + delta.x, 1e-9, "effect X")
  Assert.near(afterEffect.localZ, beforeEffect.localZ + delta.z, 1e-9, "effect Z")
  Assert.near(afterEffect.worldY, beforeEffect.worldY + delta.y, 1e-9, "effect Y")
  coverage:release()
end

return { metadata = { capabilities = {} }, tests = T }
