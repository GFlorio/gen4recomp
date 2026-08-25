-- Contract tests for strict physical-cell topology and runtime addressing.

local Assert = require("tests.support.Assert")
local FieldCellCache = require("libs.assets.src.FieldCellCache")

local T = {}

local function index()
  return {
    schema = FieldCellCache.INDEX_SCHEMA,
    matrices = {
      {
        matrixMemberId = 4,
        width = 3,
        height = 2,
        cells = {
          {
            matrixMemberId = 4,
            index = 1,
            x = 1,
            z = 0,
            mapHeaderId = 60,
            altitude = 2,
            landDataMemberId = 7,
            areaDataMemberId = 2,
            file = FieldCellCache.cellPath(4, 1),
          },
        },
      },
    },
  }
end

function T.resolves_physical_coordinate_without_logical_map()
  local entry = FieldCellCache.find(index(), 4, 1, 0)
  Assert.isTrue(entry ~= nil)
  entry = assert(entry)
  Assert.equal(entry.file, "data/generated/field/cells/4/1/cell.lua")
  Assert.isNil(FieldCellCache.find(index(), 4, 2, 0))
end

function T.rejects_duplicate_coordinates()
  local value = index()
  local first = value.matrices[1].cells[1]
  local duplicate = {}
  for key, item in pairs(first) do
    duplicate[key] = item
  end
  duplicate.index = 2
  value.matrices[1].cells[2] = duplicate
  local fs = {
    read = function()
      return "marker"
    end,
    loadLua = function(_, path)
      if path == FieldCellCache.indexPath() then
        return value
      end
      return nil
    end,
  }
  Assert.isFalse(FieldCellCache.isReady(fs, "marker"))
end

function T.rejects_malformed_collision_bytes_without_raising()
  local value = index()
  local cell = {
    schema = FieldCellCache.CELL_SCHEMA,
    matrixMemberId = 4,
    index = 1,
    x = 1,
    z = 0,
    mapHeaderId = 60,
    altitude = 2,
    landDataMemberId = 7,
    areaDataMemberId = 2,
    collision = { file = "collision.g4collision", width = 32, height = 32 },
    terrain = { file = "terrain.lua" },
    batches = {},
    materials = {},
    buildingInstances = {},
  }
  local fs = {
    read = function(_, path)
      if path == FieldCellCache.markerPath() then
        return "marker"
      end
      return "not-a-g4collision"
    end,
    loadLua = function(_, path)
      if path == FieldCellCache.indexPath() then
        return value
      end
      if path == value.matrices[1].cells[1].file then
        return cell
      end
      return nil
    end,
    exists = function(_, path)
      return path == cell.collision.file or path == cell.terrain.file
    end,
  }
  local ok, ready = pcall(FieldCellCache.isReady, fs, "marker")
  Assert.isTrue(ok, "malformed collision data must be an invalid cache, not an exception")
  Assert.isFalse(ready)
end

return { metadata = { capabilities = {} }, tests = T }
