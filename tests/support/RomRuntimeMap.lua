-- Compiles one runtime field map (terrain, collision, field data, and
-- coordinate origin) straight from a ROM dump through the project compilers.
-- Shared by the ROM conformance suite's warp, interaction, and demo-path tests so
-- the runtime-map shape lives in one place. `assets` may be a bundle already
-- produced by MapAssetCompiler.compile (the scene-loader fixture reuses one
-- compile for both the loader cache and the runtime map).

local CollisionGrid = require("libs.engine.src.CollisionGrid")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local Hashing = require("romdump.src.digest.Hashing")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local RomRuntimeMap = {}

---@param romFs table
---@param symbol string|integer
---@param assets table|nil -- a pre-compiled MapAssetCompiler bundle to reuse
---@return table
function RomRuntimeMap.compile(romFs, symbol, assets)
  assets = assets or assert(MapAssetCompiler.compile(romFs, symbol))
  local field = assert(FieldMapDataCompiler.compile(romFs, symbol)).field
  local matrix = assets.scene.matrix
  return {
    mapId = assets.scene.mapId,
    coordinateOrigin = { x = matrix.worldOriginX, z = matrix.worldOriginZ },
    fieldData = field,
    collision = CollisionGrid.new(assets.collision, {
      worldOriginX = matrix.worldOriginX,
      worldOriginZ = matrix.worldOriginZ,
    }),
    terrain = TerrainSurface.new(assets.terrain),
    terrainDependencyHash = Hashing.hashLua(assets.terrain),
    -- Mirrors the FieldMapLoader aggregate shape: the field clock entry fans
    -- out to the presentation runtimes the ROM harness installs (scene, and
    -- coverage when composed), and stays a safe no-op without them.
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
      if self.coverageRuntime then
        self.coverageRuntime:updateAnimated()
      end
    end,
  }
end

return RomRuntimeMap
