-- FieldTerrainEffectRenderer tests that physical effect anchors use the
-- runtime's authoritative C04 projection instead of a stale origin/Y copy.

local Assert = require("tests.support.Assert")

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

T.tests["projects stable effect anchors through the runtime map"] = function()
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
        drawItems = function(self)
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
      tall_grass = { model = MODEL },
      very_tall_grass = { model = MODEL },
    },
  }, pool)
  local calls = 0
  local runtimeMap = {
    projectPhysicalPoint = function(_, fieldX, fieldZ, cellKey, sourceSurfaceId)
      calls = calls + 1
      Assert.equal(fieldX, 34)
      Assert.equal(fieldZ, 5)
      Assert.equal(cellKey, "1:0")
      Assert.equal(sourceSurfaceId, 3)
      return {
        worldX = 101.25,
        worldY = 202.5,
        worldZ = 303.75,
      }
    end,
  }
  local items = renderer:drawItems({
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
  }, runtimeMap)

  Assert.equal(calls, 1)
  Assert.equal(#items, 1)
  Assert.equal(items[1].transform[13], 101.25)
  Assert.equal(items[1].transform[14], 202.5)
  Assert.equal(items[1].transform[15], 303.75)
  Assert.equal(items[1].fieldEffect, "tall_grass")
  renderer:dispose()
  for _, name in ipairs(moduleNames) do
    package.loaded[name] = saved[name]
  end
end

return T
