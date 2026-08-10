-- Tests for NeighborRing.load: it turns compiled scene.neighbors descriptors
-- into GPU draws, reading geometry/textures from a cacheFs, baking each cell's
-- world offset into the draw transform and sort center, and deduplicating a
-- shared geometry path across cells into a single owned mesh. love-backed (it
-- builds real meshes/images) but ROM-free: cacheFs bytes are canned in-process.
-- load() needs a graphics context, so these skip in the headless suite, matching
-- map_renderer_test.

local Assert = require("tests.support.Assert")
local MeshWriter = require("libs.assets.src.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local NeighborRing = require("libs.engine.src.NeighborRing")

local T = {}

local function hasGraphics()
  return love and love.graphics and love.graphics.newMesh
end

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
  if not hasGraphics() then
    return
  end
  local cacheFs, geomPath, texPath = fakeCacheFs()
  local ring = NeighborRing.load(cacheFs, descriptors(geomPath, texPath))

  Assert.equal(#ring.draws, 2) -- one batch per cell
  Assert.equal(ring.stats.cellCount, 2)

  -- The triangle's model-space center is (2/3, 0, 2/3); each draw bakes its
  -- cell offset into both the transform translation and the sort center.
  local d1 = ring.draws[1]
  Assert.equal(d1.transform[13], 32) -- translate X column of Matrix4
  Assert.equal(d1.transform[15], 0) -- translate Z
  Assert.isTrue(math.abs(d1.center[1] - (2 / 3 + 32)) < 1e-4, "center X offset baked")
  Assert.isTrue(math.abs(d1.center[3] - (2 / 3 + 0)) < 1e-4, "center Z offset baked")

  local d2 = ring.draws[2]
  Assert.equal(d2.transform[13], -32)
  Assert.equal(d2.transform[15], -32)
  Assert.isTrue(d2.submissionIndex > d1.submissionIndex, "submission indices are stable/ascending")
  Assert.isTrue(d1.submissionIndex > 200000, "submission base is 200000")

  ring:release()
end

function T.dedups_shared_geometry_into_one_owned_mesh()
  if not hasGraphics() then
    return
  end
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
  if not hasGraphics() then
    return
  end
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

return T
