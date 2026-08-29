-- FieldTerrainEffectRenderer tests that physical effect anchors use the
-- runtime's authoritative projection instead of a stale origin/Y copy.

local Assert = require("tests.support.Assert")
local FieldCoverage = require("libs.engine.src.FieldCoverage")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = { metadata = { capabilities = {} }, tests = {} }

local MODEL = {
  materials = {
    {
      id = 0,
      name = "grass",
      texture = "grass.png",
      wrap = { x = "clamp", y = "clamp" },
    },
  },
  batches = {
    {
      geometry = "grass.mesh",
      material = 0,
      alphaClass = "cutout",
      cullMode = "back",
      polygonAlpha = 31,
      polygonMode = "modulation",
      polygonId = 0,
      translucentDepthWrite = false,
      depthEqual = false,
      lightMask = 15,
      fogEnabled = false,
    },
  },
}

local function newRenderer()
  local moduleNames = {
    "libs.engine.src.FieldTerrainEffectRenderer",
    "libs.engine.src.ModelDefinition",
    "libs.engine.src.ModelInstance",
    "libs.engine.src.SceneDescriptor",
  }
  local saved = {}
  for _, name in ipairs(moduleNames) do
    saved[name] = package.loaded[name]
  end
  package.loaded["libs.engine.src.ModelDefinition"] = {
    fromNitroDescriptor = function(_, descriptor)
      return { key = descriptor.key, meshes = { { id = "grass", geometry = "grass.mesh" } } }
    end,
  }
  package.loaded["libs.engine.src.ModelInstance"] = {
    new = function()
      return {
        transform = {},
        evaluatePose = function() end,
        drawItems = function(self, renderMeshesById)
          assert(type(renderMeshesById) == "table", "terrain renderer must provide render meshes")
          return { { transform = self.transform } }
        end,
      }
    end,
  }
  package.loaded["libs.engine.src.SceneDescriptor"] = {
    wrapByMaterial = function()
      return { [0] = { x = "clamp", y = "clamp" } }
    end,
  }
  package.loaded["libs.engine.src.FieldTerrainEffectRenderer"] = nil
  local Renderer = require("libs.engine.src.FieldTerrainEffectRenderer")
  local pool = {
    build = function(_, fn)
      return fn()
    end,
    meshFor = function()
      return { mesh = {}, center = { 0, 0, 0 } }
    end,
    imageFor = function()
      return {}
    end,
  }
  local renderer = Renderer.new({
    effects = {
      tall_grass = { model = MODEL, placementOffset = { x = 0, y = 0, z = 0.625 } },
      very_tall_grass = { model = MODEL, placementOffset = { x = 0, y = 0, z = 0.625 } },
    },
  }, pool)
  local function cleanup()
    renderer:dispose()
    for _, name in ipairs(moduleNames) do
      package.loaded[name] = saved[name]
    end
  end
  return renderer, cleanup
end

local function projectionCoverage()
  local cells = {}
  local index = 0
  for z = -1, 1 do
    for x = -1, 1 do
      cells[#cells + 1] = {
        matrixMemberId = 1,
        index = index,
        x = x,
        z = z,
        origin = { x = x * 32, y = 0, z = z * 32 },
        terrain = { file = "data/generated/field/cells/projection/terrain.lua" },
      }
      index = index + 1
    end
  end
  return FieldCoverage.new({
    matrixMemberId = 1,
    index = {
      schema = "g4-field-cell-index-v2",
      matrices = { { matrixMemberId = 1, width = 3, height = 3, cells = cells } },
    },
    anchorX = 0,
    anchorZ = 0,
    loadCell = function(descriptor)
      return {
        key = string.format("%d:%d", descriptor.x, descriptor.z),
        x = descriptor.x,
        z = descriptor.z,
        origin = descriptor.origin,
        collision = {
          containsLocal = function()
            return true
          end,
        },
        terrain = TerrainSurface.new({
          source = { bdhcSha1 = "projection-" .. descriptor.x .. ":" .. descriptor.z },
          plates = {
            {
              id = 7,
              minX = 0,
              minZ = 0,
              maxX = 32,
              maxZ = 32,
              normal = { x = 0, y = 1, z = 0 },
              distance = 3,
            },
          },
        }),
        release = function() end,
      }
    end,
  })
end

local function meshlessModelInstance()
  return {
    transform = {},
    evaluatePose = function() end,
    drawItems = function(self, renderMeshesById)
      assert(type(renderMeshesById) == "table", "terrain renderer must provide render meshes")
      return { { transform = self.transform } }
    end,
  }
end

T.tests["empty status does not require physical projection"] = function()
  local renderer, cleanup = newRenderer()
  local ok, err = pcall(function()
    local items = renderer:drawItems({ instances = {} }, {})
    Assert.equal(#items, 0)
  end)
  cleanup()
  Assert.isTrue(ok, tostring(err))
end

T.tests["active status requires physical projection"] = function()
  local renderer, cleanup = newRenderer()
  local ok, err = pcall(function()
    renderer:drawItems({
      instances = {
        {
          kind = "tall_grass",
          fieldX = 2,
          fieldZ = 5,
          cellKey = "0:0",
          sourceSurfaceId = 7,
          modelInstance = renderer:newInstance("tall_grass"),
        },
      },
    }, {})
  end)
  cleanup()
  Assert.isFalse(ok)
  Assert.isTrue(tostring(err):find("terrain effect runtime map projection is required", 1, true) ~= nil)
end

T.tests["coverage projection places grass on the centered tile"] = function()
  local coverage = projectionCoverage()
  local renderer, cleanup = newRenderer()
  local runtimeMap = {
    projectPhysicalPoint = function(_, fieldX, fieldZ, cellKey, sourceSurfaceId)
      return coverage:project(fieldX, fieldZ, cellKey, sourceSurfaceId)
    end,
  }
  local ok, result = pcall(function()
    return renderer:drawItems({
      instances = {
        {
          kind = "tall_grass",
          fieldX = 2,
          fieldZ = 5,
          cellKey = "0:0",
          sourceSurfaceId = 7,
          modelInstance = meshlessModelInstance(),
        },
      },
    }, runtimeMap)
  end)
  cleanup()
  coverage:release()
  Assert.isTrue(ok, tostring(result))
  Assert.equal(#result, 1)
  Assert.equal(result[1].transform[13], -13.5)
  Assert.equal(result[1].transform[14], 3)
  Assert.equal(result[1].transform[15], -9.875)
  Assert.equal(result[1].fieldEffect, "tall_grass")
end

T.tests["applies source placement after projection across a rebase"] = function()
  local renderer, cleanup = newRenderer()
  local calls = 0
  local runtimeMap = {
    projectPhysicalPoint = function(_, fieldX, fieldZ, cellKey, sourceSurfaceId)
      calls = calls + 1
      Assert.equal(fieldX, 34)
      Assert.equal(fieldZ, 5)
      Assert.equal(cellKey, "1:0")
      Assert.equal(sourceSurfaceId, 3)
      return calls == 1 and {
        worldX = 101.25,
        worldY = 202.5,
        worldZ = 303.75,
      } or {
        worldX = 1.25,
        worldY = 2.5,
        worldZ = 3.75,
      }
    end,
  }
  local status = {
    instances = {
      {
        kind = "tall_grass",
        fieldX = 34,
        fieldZ = 5,
        worldY = -99,
        cellKey = "1:0",
        sourceSurfaceId = 3,
        modelInstance = renderer:newInstance("tall_grass"),
      },
    },
  }
  local first = renderer:drawItems(status, runtimeMap)

  Assert.equal(#first, 1)
  Assert.equal(first[1].transform[13], 101.25)
  Assert.equal(first[1].transform[14], 202.5)
  Assert.equal(first[1].transform[15], 304.375)

  local second = renderer:drawItems(status, runtimeMap)
  Assert.equal(calls, 2)
  Assert.equal(#second, 1)
  Assert.equal(second[1].transform[13], 1.25)
  Assert.equal(second[1].transform[14], 2.5)
  Assert.equal(second[1].transform[15], 4.375)
  Assert.equal(second[1].fieldEffect, "tall_grass")
  cleanup()
end

return T
