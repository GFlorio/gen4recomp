-- Private Epic 8 target facts resolve the compiled Elm/New Bark warp pair all
-- the way through destination terrain selection without hardcoded endpoints.

local Assert = require("tests.support.Assert")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local CollisionGrid = require("libs.engine.src.CollisionGrid")
local PermissionGrid = require("libs.assets.src.PermissionGrid")
local TerrainSurface = require("libs.engine.src.TerrainSurface")
local WarpSystem = require("libs.engine.src.WarpSystem")

local T = {}

local function runtimeMap(romFs, symbol)
  local assets = assert(MapAssetCompiler.compile(romFs, symbol))
  local field = assert(FieldMapDataCompiler.compile(romFs, symbol)).field
  local matrix = assets.scene.matrix
  local permissions = assert(PermissionGrid.decode(assets.permissions,
    { mapId = assets.scene.mapId }))
  return {
    mapId = assets.scene.mapId,
    coordinateOrigin = { x = matrix.worldOriginX, z = matrix.worldOriginZ },
    fieldData = field,
    permissions = CollisionGrid.new(permissions, {
      worldOriginX = matrix.worldOriginX, worldOriginZ = matrix.worldOriginZ,
    }),
    terrain = TerrainSurface.new(assets.terrain),
  }
end

function T.elms_lab_and_new_bark_warps_resolve_both_directions(romFs)
  local maps = {
    [60] = runtimeMap(romFs, "MAP_NEW_BARK"),
    [61] = runtimeMap(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"),
  }
  local loader = { load = function(_, mapId) return assert(maps[mapId]) end }

  local labWarp = assert(WarpSystem.findAt(maps[61], 4, 14))
  local outside = WarpSystem.resolveDestination(loader, maps[61], labWarp)
  Assert.equal(outside.destinationMap.mapId, 60)
  Assert.equal(outside.destinationWarp.index, 0)
  Assert.equal(outside.fieldX, 684)
  Assert.equal(outside.fieldZ, 393)
  Assert.notNil(maps[60].terrain:plate(outside.surfaceId))

  local townWarp = assert(WarpSystem.findAt(maps[60], 684, 393))
  local inside = WarpSystem.resolveDestination(loader, maps[60], townWarp)
  Assert.equal(inside.destinationMap.mapId, 61)
  Assert.equal(inside.destinationWarp.index, 0)
  Assert.equal(inside.fieldX, 4)
  Assert.equal(inside.fieldZ, 14)
  Assert.notNil(maps[61].terrain:plate(inside.surfaceId))
end

return T
