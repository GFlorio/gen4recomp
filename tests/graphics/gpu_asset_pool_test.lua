-- Tests for the shared GPU asset pool used by MapSceneLoader and NeighborRing:
-- content-addressed mesh/image dedup, sampler-aware image identity (the wrap
-- pair is part of the key, so two materials sharing pixels but sampling them
-- differently never alias one mutable sampler), unknown wrap rejection, and
-- exactly-once ownership release. Failure handling has two scopes, mirroring
-- the two production failure classes: a transaction wrapper rolls back every
-- object created inside a failed construction (the whole scene build), while
-- a single post-construction acquire failure rolls back only the object that
-- acquisition itself created -- the live scene keeps the resources it is
-- drawing. The image side runs headless through an injected fake graphics
-- namespace; mesh construction needs a real graphics context, so this is a
-- graphics suite.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
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
-- newImage call raise; failSetWrapOn makes the Nth created image's setWrap
-- raise after creation -- together they exercise failed-acquire cleanup both
-- before and after the failed acquisition created its own object, headless.
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
      local image = { released = false, index = newImageCalls }
      image.setFilter = function() end
      image.setWrap = function(_, wx, wy)
        if opts.failSetWrapOn == image.index then
          error("injected setWrap failure")
        end
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

function T.rejects_a_missing_graphics_namespace()
  local err = Assert.throws(function()
    ---@diagnostic disable: assign-type-mismatch
    GpuAssetPool.new(fakeCacheFs(), { graphics = false })
  end)
  Assert.isTrue(tostring(err):find("GpuAssetPool requires love.graphics", 1, true) ~= nil)
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

-- Construction rollback: the whole scene build runs inside a transaction
-- wrapper (MapSceneLoader.load and the NeighborRing load path), so the Nth
-- acquire failing must roll back every object created inside the transaction
-- -- a partially failed construction never leaks GPU objects.
function T.transaction_releases_everything_when_the_second_acquire_fails()
  local graphics = fakeGraphics({ failOnNewImage = 2 })
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local err = Assert.throws(function()
    pool:transaction(function()
      pool:imageFor(TEX_PATH, "clamp", "clamp")
      pool:imageFor(TEX_PATH, "repeat", "repeat")
    end)
  end)
  Assert.isTrue(tostring(err):find("injected newImage failure", 1, true) ~= nil, "rethrows the image build failure")
  Assert.equal(graphics.images[1].released, true, "the transaction rolls back the first image")
  Assert.equal(#pool.images, 0, "the pool owns nothing after the failed construction")
  local retry = pool:imageFor(TEX_PATH, "clamp", "clamp")
  Assert.isTrue(retry ~= nil, "the pool is usable after the rollback")
  Assert.equal(#pool.images, 1)
  Assert.equal(graphics.images[2].released, false, "the rebuilt image is owned, not a released leftover")
end

-- The transaction is not a release-everything-on-exit wrapper: a successful
-- construction keeps its objects owned and returns the builder's value.
function T.transaction_keeps_objects_and_returns_the_value_on_success()
  local graphics = fakeGraphics()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local result = pool:transaction(function()
    pool:imageFor(TEX_PATH, "clamp", "clamp")
    return "built"
  end)
  Assert.equal(result, "built", "the transaction returns the builder's value")
  Assert.equal(graphics.images[1].released, false, "a successful construction keeps its objects")
  Assert.equal(#pool.images, 1)
end

-- A nested transaction would release the outer construction's objects on the
-- inner rollback, so nesting is rejected outright.
function T.transaction_rejects_nesting()
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = fakeGraphics() })
  local err = Assert.throws(function()
    pool:transaction(function()
      pool:transaction(function() end)
    end)
  end)
  Assert.isTrue(tostring(err):find("not nestable", 1, true) ~= nil, "rejects a nested transaction")
end

-- Post-construction failure: a single lazy acquire failing while the live
-- scene draws must release only the object that failed acquisition itself
-- created -- never the earlier resources the scene is using. The failure is
-- injected after the second image was created (setWrap), so the failed
-- acquisition does own an object to roll back.
function T.failed_single_acquire_releases_only_its_own_object()
  local graphics = fakeGraphics({ failSetWrapOn = 2 })
  local pool = GpuAssetPool.new(fakeCacheFs(), { graphics = graphics })
  local first = pool:imageFor(TEX_PATH, "clamp", "clamp")
  local err = Assert.throws(function()
    pool:imageFor(TEX_PATH, "repeat", "repeat")
  end)
  Assert.isTrue(tostring(err):find("injected setWrap failure", 1, true) ~= nil, "rethrows the configuration failure")
  Assert.equal(graphics.images[1].released, false, "the earlier image stays alive after a single failed acquire")
  Assert.equal(graphics.images[2].released, true, "the failed acquire's own object is released")
  Assert.equal(#pool.images, 1, "the pool still owns only the earlier image")
  Assert.equal(first, graphics.images[1])
  local retry = pool:imageFor(TEX_PATH, "repeat", "repeat")
  Assert.isTrue(retry ~= nil, "the failed sampler state is acquirable again")
  Assert.equal(graphics.images[3].released, false, "the rebuilt image is owned, not a released cache leftover")
  Assert.equal(#pool.images, 2)
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
  metadata = { capabilities = { "graphics" } },
  tests = T,
}
