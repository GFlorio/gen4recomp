-- NeighborRing loader tests: the sampler-wrap loader boundary for the eight
-- surrounding-cell ring mirrors MapSceneLoader's -- a cell material's raw
-- descriptor wrap/flip pair must resolve through SceneDescriptor.wrap()
-- before the image reaches the GPU pool, never the raw record.wrap.x/y the
-- old materialsById passed straight through. Headless: the pool's
-- meshBuilder/imageBuilder seams and a stub graphics namespace stand in for
-- real love GPU resources, so this suite needs no graphics capability.

local Assert = require("tests.support.Assert")
local NeighborRing = require("libs.hgss.src.presentation.NeighborRing")
local MeshWriter = require("libs.assets.src.MeshWriter")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local STUB_GRAPHICS = {
  newImage = function()
    error("neighbor_ring does not build images in this test")
  end,
}
---@cast STUB_GRAPHICS GpuAssetPool.Graphics

-- A fake mesh builder for the pool's GPU seam: SceneMesh.decode output
-- becomes a plain object, so the ring's assembly runs headless.
local function fakeMeshBuilder(decoded)
  return {
    id = decoded and decoded.name or "mesh",
    release = function() end,
  }
end

-- Records every image built and the wrap pair(s) the pool later configures
-- it with (image:setWrap(wrapX, wrapY)) -- the observable request reaching
-- the GPU abstraction.
local function recordingImageBuilder(images)
  return function(path)
    local image = { path = path, wraps = {} }
    image.setFilter = function() end
    image.setWrap = function(_, wrapX, wrapY)
      image.wraps[#image.wraps + 1] = { wrapX, wrapY }
    end
    image.release = function() end
    images[#images + 1] = image
    return image
  end
end

-- A 2x2-tile quad in tile space (MeshWriter vertex shape).
local function quad()
  local function v(x, z)
    return {
      x = x,
      y = 0,
      z = z,
      u = 0,
      v = 0,
      nx = 0,
      ny = 1,
      nz = 0,
      r = 255,
      g = 255,
      b = 255,
      a = 255,
      colorSource = 0,
    }
  end
  return {
    vertices = { v(0, 0), v(2, 0), v(2, 2), v(0, 2) },
    indices = { 0, 1, 2, 0, 2, 3 },
  }
end

-- One neighbor cell descriptor with one material and one batch sampling it,
-- the scene-form shape MapAssetCompiler emits per drawn surrounding cell.
local function cell(offsetX, offsetY, offsetZ, material, geometryPath)
  return {
    offsetTilesX = offsetX,
    offsetTilesY = offsetY,
    offsetTilesZ = offsetZ,
    materials = { material },
    batches = {
      {
        geometry = geometryPath,
        material = material.id,
        cullMode = "back",
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        polygonAlpha = 31,
        lightMask = 0,
        alphaClass = "opaque",
        fogEnabled = false,
      },
    },
  }
end

-- A cell material's raw descriptor state (`wrap.x = "repeat"`,
-- `flip.x = true`) must reach the GPU image as the resolved DS
-- mirrored-repeat sampler -- the same loader-boundary requirement
-- MapSceneLoader must satisfy, proven independently through NeighborRing.
function T.neighbor_material_with_flip_resolves_to_mirrored_repeat()
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local material = {
    id = 0,
    name = "ground",
    texture = "neighbor-ground.png",
    wrap = { x = "repeat", y = "repeat" },
    flip = { x = true, y = false },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
  }
  local descriptors = { cell(32, 1, 0, material, geometryPath) }
  local images = {}
  local ring = NeighborRing.load(backend, descriptors, {
    meshBuilder = fakeMeshBuilder,
    imageBuilder = recordingImageBuilder(images),
    graphics = STUB_GRAPHICS,
  })
  Assert.equal(#images, 1, "one pooled image for the one cell material")
  Assert.deepEqual(
    images[1].wraps,
    { { "mirroredrepeat", "repeat" } },
    "the neighbor image is requested with the resolved mirrored-repeat wrap, not the raw repeat pair"
  )
  ring:release()
end

function T.neighbor_vertical_offset_reaches_the_draw_transform()
  local geometryPath = "assets/generated/maps/geometry/neighbor-quad.g4mesh"
  local backend = FakeCache.new()
  backend:write(geometryPath, MeshWriter.encode(quad()))
  local material = {
    id = 0,
    name = "ground",
    texture = "neighbor-ground.png",
    wrap = { x = "repeat", y = "repeat" },
    flip = { x = false, y = false },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
  }
  local ring = NeighborRing.load(backend, { cell(32, 1, -32, material, geometryPath) }, {
    meshBuilder = fakeMeshBuilder,
    imageBuilder = recordingImageBuilder({}),
    graphics = STUB_GRAPHICS,
  })
  Assert.equal(ring.draws[1].transform[13], 32)
  Assert.equal(ring.draws[1].transform[14], 1)
  Assert.equal(ring.draws[1].transform[15], -32)
  ring:release()
end

return { tests = T }
