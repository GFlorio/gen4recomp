-- Compiles one runtime field map (terrain, permissions, field data, and
-- coordinate origin) straight from a ROM dump through the project compilers.
-- Shared by the private suite's warp, interaction, and demo-path tests so
-- the runtime-map shape lives in one place.

local CollisionGrid = require("libs.engine.src.CollisionGrid")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local PermissionGrid = require("libs.assets.src.PermissionGrid")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local RomRuntimeMap = {}

---@param romFs table
---@param symbol string
---@return table
function RomRuntimeMap.compile(romFs, symbol)
  local assets = assert(MapAssetCompiler.compile(romFs, symbol))
  local field = assert(FieldMapDataCompiler.compile(romFs, symbol)).field
  local matrix = assets.scene.matrix
  local permissions = assert(PermissionGrid.decode(assets.permissions, { mapId = assets.scene.mapId }))
  return {
    mapId = assets.scene.mapId,
    coordinateOrigin = { x = matrix.worldOriginX, z = matrix.worldOriginZ },
    fieldData = field,
    permissions = CollisionGrid.new(permissions, {
      worldOriginX = matrix.worldOriginX,
      worldOriginZ = matrix.worldOriginZ,
    }),
    terrain = TerrainSurface.new(assets.terrain),
    terrainDependencyHash = Hashing.hashLua(assets.terrain),
  }
end

return RomRuntimeMap
