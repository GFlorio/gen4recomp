-- Publishes the generated physical-cell class with stage, readback, and marker
-- ordering. The class owns only its cell data; shared meshes/textures remain
-- content-addressed cache assets owned by the map compiler.

local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")
local CollisionGridAsset = require("libs.assets.src.CollisionGridAsset")
local FieldCellCache = require("libs.assets.src.FieldCellCache")

local Writer = {}

local function persist(tx, bundle)
  assert(
    type(bundle.index) == "table" and type(bundle.cells) == "table" and bundle.marker,
    "incomplete field cell bundle"
  )
  local stage = tx.stage
  for _, matrix in ipairs(bundle.index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      local cell = assert(bundle.cells[descriptor.matrixMemberId .. ":" .. descriptor.index])
      assert(cell.schema == FieldCellCache.CELL_SCHEMA, "field cell schema mismatch")
      local descriptorCell = {}
      for key, value in pairs(cell) do
        if key ~= "collisionData" and key ~= "terrainData" then
          descriptorCell[key] = value
        end
      end
      stage:writeLua(descriptor.file, descriptorCell)
      stage:write(
        FieldCellCache.collisionPath(descriptor.matrixMemberId, descriptor.index),
        CollisionGridAsset.encode(cell.collisionData)
      )
      stage:writeLua(FieldCellCache.terrainPath(descriptor.matrixMemberId, descriptor.index), cell.terrainData)
    end
  end
  stage:writeLua(FieldCellCache.indexPath(), bundle.index)
  local index = FieldCellCache.loadIndex(stage)
  for _, matrix in ipairs(index.matrices) do
    for _, descriptor in ipairs(matrix.cells) do
      local cell = assert(stage:loadLua(descriptor.file))
      assert(FieldCellCache.validateCell(stage, cell), "field cell did not validate after staging")
    end
  end
  stage:write(FieldCellCache.markerPath(), bundle.marker)
  return bundle.marker
end

function Writer.isReady(cacheFs, marker)
  return FieldCellCache.isReady(cacheFs, marker)
end

function Writer.write(cacheFs, bundle)
  local tx = ArtifactPublisher.begin(cacheFs, "field-cells", { FieldCellCache.dir() })
  local ok, result = pcall(persist, tx, bundle)
  if not ok then
    tx:abort()
    error(result, 0)
  end
  tx:publish()
  return result
end

return Writer
