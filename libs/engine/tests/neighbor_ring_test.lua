-- Tests for NeighborRing.load: it turns compiled scene.neighbors descriptors
-- into GPU draws, reading geometry/textures from a cacheFs, baking each cell's
-- world offset into the draw transform and sort center, and deduplicating a
-- shared geometry path across cells into a single owned mesh. love-backed (it
-- builds real meshes/images) but ROM-free: cacheFs bytes are canned in-process.
-- load() needs a graphics context. The failure-path tests inject a fake graphics
-- namespace: a failed cell acquire or a malformed cell descriptor must
-- release every image the earlier cells already acquired.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MeshWriter = require("libs.assets.src.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local NeighborRing = require("libs.engine.src.NeighborRing")

local T = {}

-- One-triangle batch in the MeshWriter vertex layout.
local function triangleBatch()
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
  return { vertices = { v(0, 0), v(2, 0), v(0, 2) }, indices = { 0, 1, 2 } }
end

-- A cacheFs whose :read(path) returns canned bytes for the known geometry and
-- texture paths, mirroring CacheFs:read's string-or-nil contract.
local function fakeCacheFs()
  local meshBytes = MeshWriter.encode(triangleBatch())
  local pngBytes = PngWriter.encode(1, 1, string.char(255, 0, 0, 255))
  local geomPath = MapAssetCache.geometryPath("aaaa")
  local texPath = MapAssetCache.texturePath("bbbb")
  local blob = { [geomPath] = meshBytes, [texPath] = pngBytes }
  return {
    read = function(_, path)
      return blob[path]
    end,
  }, geomPath, texPath
end

-- Injected graphics namespace tracking created images and their release calls,
-- so the image side of a failed cell load can be observed without a GL context.
local function fakeGraphics()
  local images = {}
  return {
    images = images,
    newImage = function()
      local image = { released = false }
      image.setFilter = function() end
      image.setWrap = function() end
      image.release = function()
        image.released = true
      end
      images[#images + 1] = image
      return image
    end,
  }
end

-- Two cells sharing one geometry path (dedup) and one material each. `wraps`
-- optionally supplies a per-cell wrap table (indexed 1, 2) for sampler tests.
local function descriptors(geomPath, texPath, wraps)
  local function cell(ox, oz, index)
    return {
      offsetTilesX = ox,
      offsetTilesZ = oz,
      batches = {
        {
          geometry = geomPath,
          material = 0,
          alphaClass = "opaque",
          cullMode = "back",
          polygonAlpha = 31,
          polygonMode = "modulation",
          lightMask = 0,
          polygonId = 0,
          translucentDepthWrite = false,
          depthEqual = false,
        },
      },
      materials = {
        {
          id = 0,
          name = "terrain",
          texture = texPath,
          wrap = wraps and wraps[index] or { x = "repeat", y = "clamp" },
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
        },
      },
    }
  end
  return { cell(32, 0, 1), cell(-32, -32, 2) }
end

function T.builds_one_draw_per_cell_batch_with_offset_baked()
  local cacheFs, geomPath, texPath = fakeCacheFs()
  local ring = NeighborRing.load(cacheFs, descriptors(geomPath, texPath))

  Assert.equal(#ring.draws, 2) -- one batch per cell
  Assert.equal(ring.stats.cellCount, 2)

  -- The loader sorts from the triangle bounding-box center (1, 0, 1); each draw
  -- bakes its cell offset into both the transform translation and sort center.
  local d1 = ring.draws[1]
  Assert.equal(d1.transform[13], 32) -- translate X column of Matrix4
  Assert.equal(d1.transform[15], 0) -- translate Z
  Assert.isTrue(math.abs(d1.center[1] - 33) < 1e-4, "center X offset baked")
  Assert.isTrue(math.abs(d1.center[3] - 1) < 1e-4, "center Z offset baked")

  local d2 = ring.draws[2]
  Assert.equal(d2.transform[13], -32)
  Assert.equal(d2.transform[15], -32)
  Assert.isNil(d1.submissionIndex, "the ring carries no submission numbers; SceneAssembly assigns them")
  Assert.isNil(d2.submissionIndex)

  ring:release()
end

function T.dedups_shared_geometry_into_one_owned_mesh()
  local cacheFs, geomPath, texPath = fakeCacheFs()
  local ring = NeighborRing.load(cacheFs, descriptors(geomPath, texPath))
  -- Both cells reference the same geometry/texture path, so only one mesh and
  -- one image are built and owned.
  Assert.equal(ring.stats.meshCount, 1)
  Assert.equal(ring.stats.textureCount, 1)
  ring:release()
end

-- Regression for the sampler alias: two cells sharing one texture path but
-- sampling it with different wrap modes must each keep their own configured
-- image, never one mutated sampler whose state depends on load order.
function T.same_texture_with_different_wraps_gets_independent_images()
  local cacheFs, geomPath, texPath = fakeCacheFs()
  local ring = NeighborRing.load(
    cacheFs,
    descriptors(geomPath, texPath, { { x = "clamp", y = "clamp" }, { x = "repeat", y = "repeat" } })
  )
  Assert.equal(ring.stats.textureCount, 2, "one image per sampler state")
  local drawA = ring.draws[1]
  local drawB = ring.draws[2]
  Assert.isTrue(drawA.material.image ~= drawB.material.image, "wrap variants must not alias")
  local ax, ay = drawA.material.image:getWrap()
  Assert.equal(ax, "clamp")
  Assert.equal(ay, "clamp")
  local bx, by = drawB.material.image:getWrap()
  Assert.equal(bx, "repeat")
  Assert.equal(by, "repeat")
  ring:release()
end

-- A batch-free cell lets the first cell acquire its material image headless;
-- the second cell's unknown wrap then fails the load, and the first cell's
-- image must be released: a failed neighbor load cannot leak earlier cells'
-- GPU objects.
function T.failed_cell_acquire_releases_earlier_cells_images()
  local cacheFs, _, texPath = fakeCacheFs()
  local function cell(ox, wrap)
    return {
      offsetTilesX = ox,
      offsetTilesZ = 0,
      batches = {},
      materials = {
        {
          id = 0,
          name = "terrain",
          texture = texPath,
          wrap = wrap,
          diffuse = { r = 255, g = 255, b = 255, a = 255 },
        },
      },
    }
  end
  local graphics = fakeGraphics()
  local err = Assert.throws(function()
    NeighborRing.load(cacheFs, {
      cell(32, { x = "clamp", y = "clamp" }),
      cell(-32, { x = "mirror", y = "clamp" }),
    }, { graphics = graphics })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "GPU_ASSET_UNKNOWN_WRAP", "raises GPU_ASSET_UNKNOWN_WRAP")
  Assert.equal(#graphics.images, 1, "the first cell's image was acquired")
  Assert.equal(graphics.images[1].released, true, "a failed cell acquire releases the earlier cells' images")
end

-- A malformed descriptor (missing batches array) fails outside the pool after
-- earlier cells acquired images; the load must still release them.
function T.malformed_cell_descriptor_releases_earlier_cells_images()
  local cacheFs, _, texPath = fakeCacheFs()
  local first = {
    offsetTilesX = 32,
    offsetTilesZ = 0,
    batches = {},
    materials = {
      {
        id = 0,
        name = "terrain",
        texture = texPath,
        wrap = { x = "clamp", y = "clamp" },
        diffuse = { r = 255, g = 255, b = 255, a = 255 },
      },
    },
  }
  local second = {
    offsetTilesX = -32,
    offsetTilesZ = 0,
    materials = {},
  }
  local graphics = fakeGraphics()
  local ok, err = pcall(NeighborRing.load, cacheFs, { first, second }, { graphics = graphics })
  Assert.isFalse(ok, "a descriptor without a batches array fails the load: " .. tostring(err))
  Assert.equal(#graphics.images, 1, "the first cell's image was acquired")
  Assert.equal(graphics.images[1].released, true, "a malformed descriptor releases the earlier cells' images")
end

return {
  metadata = { layer = "graphics", capabilities = { "graphics" } },
  tests = T,
}
