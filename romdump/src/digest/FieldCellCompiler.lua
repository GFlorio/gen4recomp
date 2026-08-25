-- Normalizes every valid matrix cell into an independently addressable
-- runtime payload. Source interpretation stays here; the engine sees only the
-- generated index and cell contracts.

local MapCatalog = require("romdump.src.digest.MapCatalog")
local MapMatrix = require("romdump.src.digest.MapMatrix")
local NeighborChunkCompiler = require("romdump.src.digest.NeighborChunkCompiler")
local FieldCellCache = require("libs.assets.src.FieldCellCache")
local Hashing = require("romdump.src.digest.Hashing")
local Errors = require("libs.errors.src.Errors")

local Compiler = {}

local function readMember(narc, memberId)
  assert(memberId >= 0 and memberId < narc:memberCount(), "matrix member out of range")
  return assert(narc:readMember(memberId))
end

local function compile(romFs)
  local matrixNarc = assert(romFs:openNarc("map_matrices"))
  local matrices, cells = {}, {}
  local seen = {}
  local matrixMembers = {}
  for record in MapCatalog.all() do
    if not matrixMembers[record.matrixMemberId] then
      matrixMembers[record.matrixMemberId] = true
      local bytes = readMember(matrixNarc, record.matrixMemberId)
      local matrix = assert(MapMatrix.decode(bytes, record.id))
      local matrixRecord = {
        matrixMemberId = record.matrixMemberId,
        width = matrix.width,
        height = matrix.height,
        cells = {},
      }
      matrices[#matrices + 1] = matrixRecord
      for z = 0, matrix.height - 1 do
        for x = 0, matrix.width - 1 do
          local source = matrix:cell(x, z)
          local header = MapCatalog.areaForMapHeader(source.mapHeaderId)
          if header and source.landDataMemberId ~= 0xFFFF then
            local key = string.format("%d:%d", record.matrixMemberId, matrix:index(x, z))
            if not seen[key] then
              local chunk = NeighborChunkCompiler.compile(romFs, source.landDataMemberId, header.areaDataMemberId, {
                mapId = source.mapHeaderId,
                mapSymbol = header.symbol,
              })
              local index = matrix:index(x, z)
              local descriptor = {
                matrixMemberId = record.matrixMemberId,
                index = index,
                x = x,
                z = z,
                mapHeaderId = source.mapHeaderId,
                altitude = source.altitude,
                landDataMemberId = source.landDataMemberId,
                areaDataMemberId = header.areaDataMemberId,
                file = FieldCellCache.cellPath(record.matrixMemberId, index),
              }
              matrixRecord.cells[#matrixRecord.cells + 1] = descriptor
              cells[key] = {
                schema = FieldCellCache.CELL_SCHEMA,
                matrixMemberId = record.matrixMemberId,
                index = index,
                x = x,
                z = z,
                mapHeaderId = source.mapHeaderId,
                altitude = source.altitude,
                landDataMemberId = source.landDataMemberId,
                areaDataMemberId = header.areaDataMemberId,
                batches = chunk.batches,
                materials = chunk.materials,
                buildingInstances = {},
                terrainAnimations = { textureSrt = false },
                collision = {
                  width = 32,
                  height = 32,
                  file = FieldCellCache.collisionPath(record.matrixMemberId, index),
                },
                terrain = {
                  schema = chunk.terrain.schema,
                  file = FieldCellCache.terrainPath(record.matrixMemberId, index),
                },
                collisionData = chunk.collision,
                terrainData = chunk.terrain,
              }
              seen[key] = true
            end
          end
        end
      end
    end
  end
  table.sort(matrices, function(a, b)
    return a.matrixMemberId < b.matrixMemberId
  end)
  for _, matrix in ipairs(matrices) do
    table.sort(matrix.cells, function(a, b)
      return a.index < b.index
    end)
  end
  local dependency = Hashing.hashLua(matrices)
  return {
    marker = FieldCellCache.marker(romFs:metadata().sha1, dependency),
    index = { schema = FieldCellCache.INDEX_SCHEMA, matrices = matrices },
    cells = cells,
  }
end

function Compiler.compile(romFs)
  assert(romFs and romFs.openNarc, "field cell compilation requires RomFs")
  local ok, result = pcall(compile, romFs)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return Compiler
