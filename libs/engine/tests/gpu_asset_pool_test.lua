-- Tests for the shared GPU asset pool used by MapSceneLoader and NeighborRing:
-- content-addressed mesh/image dedup, sampler-aware image identity (the wrap
-- pair is part of the key, so two materials sharing pixels but sampling them
-- differently never alias one mutable sampler), unknown wrap rejection, and
-- exactly-once ownership release including cleanup on a failed acquire. The
-- image side runs headless through an injected fake graphics namespace; mesh
-- construction needs a real graphics context, so this is a graphics suite.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local MapAssetCache = require("libs.assets.src.MapAssetCache")
local MeshWriter = require("libs.assets.src.MeshWriter")
local PngWriter = require("libs.assets.src.PngWriter")
local GpuAssetPool = require("libs.engine.src.GpuAssetPool")

local T = {}

local GEOM_PATH = MapAssetCache.geometryPath("aaaa")
local TEX_PATH = MapAssetCache.texturePath("bbbb")

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

-- A CacheFs whose :read(path) serves canned bytes for the known paths,
-- mirroring CacheFs:read's string-or-nil contract.
local function fakeCacheFs()
  local blob = {
    [GEOM_PATH] = MeshWriter.encode(triangleBatch()),
    [TEX_PATH] = PngWriter.encode(1, 1, string.char(255, 0, 0, 255)),
  }
  return {
    read = function(_, path)
      return blob[path]
    end,
  }
end

-- Injected graphics namespace: tracks created images, the wrap pair each image
-- was configured with, and release calls. failOnNewImage makes the Nth
-- newImage call raise, so failed-acquire cleanup can be exercised headless.
local function fakeGraphics(opts)
  opts = opts or {}
  local images = {}
  local wraps = {}
  local newImageCalls = 0
  return {
    images = images,
    wraps = wraps,
    newImage = function()
      newImageCalls = newImageCalls + 1
      if opts.failOnNewImage == newImageCalls then
        error("injected newImage failure")
      end
      local image = { released = false }
      image.setFilter = function() end
      image.setWrap = function(_, wx, wy)
        wraps[#wraps + 1] = { wx, wy }
      end
      image.release = function()
        image.released = true
      end
      images[#images + 1] = image
      return image
    end,
  }
end

function T.unknown_wrap_modes_are_rejected()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics() })
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "mirror", "clamp")
  end)
  Assert.isTrue(Errors.is(err) and err.code == "GPU_ASSET_UNKNOWN_WRAP", "raises GPU_ASSET_UNKNOWN_WRAP")
  Assert.equal(#pool.images, 0, "no image was created")
end

function T.image_identity_includes_the_wrap_pair()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local repeatX = pool:imageFor(TEX_PATH, "repeat", "clamp")
  local clampX = pool:imageFor(TEX_PATH, "clamp", "clamp")
  Assert.isTrue(repeatX ~= clampX, "different wrap pairs must not alias one image")
  Assert.deepEqual(graphics.wraps[1], { "repeat", "clamp" })
  Assert.deepEqual(graphics.wraps[2], { "clamp", "clamp" })
  Assert.equal(#pool.images, 2)
end

function T.same_path_and_wrap_dedup_to_one_owned_image()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local first = pool:imageFor(TEX_PATH, "repeat", "clamp")
  local second = pool:imageFor(TEX_PATH, "repeat", "clamp")
  Assert.equal(first, second)
  Assert.equal(#pool.images, 1)
  Assert.equal(#graphics.images, 1, "the underlying love image is built once")
end

function T.untextured_materials_get_no_image()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics() })
  Assert.isNil(pool:imageFor(nil, "clamp", "clamp"))
  Assert.equal(#pool.images, 0)
end

function T.failed_image_build_releases_already_created_images()
  local graphics = fakeGraphics({ failOnNewImage = 2 })
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  pool:imageFor(TEX_PATH, "clamp", "clamp")
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "repeat", "repeat")
  end)
  Assert.isTrue(tostring(err):find("injected newImage failure", 1, true) ~= nil, "rethrows the image build failure")
  Assert.equal(graphics.images[1].released, true, "the earlier image is released")
  Assert.equal(#pool.images, 0, "the pool owns nothing after the failure")
end

function T.unknown_wrap_on_a_later_acquire_releases_prior_images()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  pool:imageFor(TEX_PATH, "clamp", "clamp")
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "wrapy", "clamp")
  end)
  Assert.isTrue(Errors.is(err) and err.code == "GPU_ASSET_UNKNOWN_WRAP", "raises GPU_ASSET_UNKNOWN_WRAP")
  Assert.equal(graphics.images[1].released, true, "the earlier image is released")
  Assert.equal(#pool.images, 0)
end

function T.release_is_exactly_once_and_repeat_safe()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  pool:imageFor(TEX_PATH, "clamp", "clamp")
  pool:imageFor(TEX_PATH, "repeat", "clamp")
  pool:release()
  pool:release()
  Assert.equal(graphics.images[1].released, true)
  Assert.equal(graphics.images[2].released, true)
  Assert.equal(#pool.images, 0)
  Assert.equal(#pool.meshes, 0)
end

function T.mesh_entries_dedup_and_accumulate_triangles_once()
  local pool = GpuAssetPool.new(fakeCacheFs())
  local first = pool:meshFor(GEOM_PATH)
  local second = pool:meshFor(GEOM_PATH)
  Assert.equal(first.mesh, second.mesh)
  Assert.equal(first.verts, second.verts)
  Assert.equal(first.triangles, 1)
  Assert.equal(pool.triangles, 1, "shared geometry is counted once")
  Assert.equal(#pool.meshes, 1)
  pool:release()
end

return {
  metadata = { layer = "graphics", capabilities = { "graphics" } },
  tests = T,
}
