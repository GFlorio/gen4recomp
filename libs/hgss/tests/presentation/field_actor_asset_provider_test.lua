-- Lifecycle tests for the runtime actor asset provider, driven against an
-- in-memory cache and a stub graphics namespace so no GPU resource is created.
-- Covers sharing, reference balance, idle eviction, statistics, and the fatal
-- errors a missing or uncompiled sprite must produce.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.field.FieldActorCache")
local FieldActorAssetProvider = require("libs.hgss.src.presentation.FieldActorAssetProvider")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

-- Records every image it creates so a test can assert on releases.
local function stubGraphics(created, opts)
  opts = opts or {}
  local meshCalls = 0
  return {
    newImage = function()
      local image = { released = false, quads = 0 }
      function image:getWidth()
        return 64
      end
      function image:getHeight()
        return 32
      end
      function image:setFilter(min, mag)
        self.filter = { min, mag }
      end
      function image:release()
        self.released = true
      end
      created[#created + 1] = image
      return image
    end,
    newQuad = function(x, y, w, h)
      return { x = x, y = y, w = w, h = h }
    end,
    newMesh = function(_, vertices)
      meshCalls = meshCalls + 1
      if opts.failOnNewMesh == meshCalls then
        error("injected newMesh failure")
      end
      local mesh = { vertices = vertices, released = false }
      function mesh:setVertexMap(map)
        self.map = map
      end
      function mesh:release()
        self.released = true
      end
      return mesh
    end,
  }
end

local function seed(spriteIds)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    romVersion = "heartgold",
    spriteIds = spriteIds,
    runtime = { avatars = {}, variableSprites = { first = 1, last = 1, variableBase = 0 } },
    variableSprites = {},
    recordCount = #spriteIds,
  })
  for _, spriteId in ipairs(spriteIds) do
    cache:writeLua(FieldActorCache.visualPath(spriteId), FieldActorFixture.visual(spriteId, { frameCount = 8 }))
    cache:write(FieldActorCache.atlasPath(spriteId), "png-bytes")
  end
  return cache
end

local function provider(spriteIds, opts, created)
  opts = opts or {}
  opts.graphics = opts.graphics or stubGraphics(created or {})
  return FieldActorAssetProvider.new(seed(spriteIds), opts)
end

function T.acquire_loads_once_and_shares_the_entry()
  local created = {}
  local p = provider({ 0, 29 }, nil, created)
  local first = p:acquire(0)
  local second = p:acquire(0)
  Assert.isTrue(first == second, "the same entry is shared")
  Assert.equal(#created, 1, "one image per sprite while referenced")
  Assert.equal(p:stats().loads, 1)
  Assert.equal(p:stats().hits, 1)
  Assert.equal(p:stats().references, 2)
end

-- DS textures are point-sampled: nearest atlas sampling must survive into
-- the actual GPU image every actor draws with, never the host's smoothing
-- default.
function T.acquired_atlas_image_is_nearest_filtered()
  local created = {}
  local p = provider({ 0 }, nil, created)
  p:acquire(0)
  Assert.deepEqual(created[1].filter, { "nearest", "nearest" })
end

function T.builds_one_quad_and_one_billboard_mesh_per_frame()
  local p = provider({ 0 })
  local entry = p:acquire(0)
  Assert.equal(#entry.quads, 8)
  Assert.equal(entry.quads[2].x, 32)
  Assert.equal(entry.quads[2].w, 32)
  Assert.equal(#entry.meshes, 8, "one world mesh per atlas frame")
  Assert.isTrue(entry.meshes[2].vertices[2][4] > 0, "frame 2 slides its U range onto the strip")
end

function T.last_release_keeps_the_entry_resident_until_evicted()
  local created = {}
  local p = provider({ 0, 29 }, { idleLimit = 1 }, created)
  p:acquire(0)
  p:release(0)
  Assert.equal(p:stats().live, 1, "an idle entry stays resident under the limit")
  Assert.equal(p:stats().idle, 1)

  p:acquire(29)
  p:release(29)
  Assert.equal(p:stats().evictions, 1)
  Assert.equal(p:stats().live, 1)
  Assert.isTrue(created[1].released, "the evicted entry released its image")
end

function T.reacquiring_an_idle_entry_is_a_hit_and_leaves_the_idle_list()
  local p = provider({ 0 }, { idleLimit = 4 })
  p:acquire(0)
  p:release(0)
  p:acquire(0)
  Assert.equal(p:stats().loads, 1)
  Assert.equal(p:stats().hits, 1)
  Assert.equal(p:stats().idle, 0)
end

function T.resident_does_not_expose_an_idle_entry_as_owned()
  local p = provider({ 0 })
  p:acquire(0)
  p:release(0)
  Assert.isNil(p:resident(0), "an idle cache entry is not presentation residency")
end

function T.dispose_releases_every_image()
  local created = {}
  local p = provider({ 0, 29 }, nil, created)
  p:acquire(0)
  p:acquire(29)
  p:dispose()
  Assert.equal(#created, 2)
  Assert.isTrue(created[1].released and created[2].released, "all images released")
  Assert.equal(p:stats().live, 0)
end

function T.mesh_construction_failure_releases_the_acquired_atlas()
  local created = {}
  local p = FieldActorAssetProvider.new(seed({ 0 }), {
    graphics = stubGraphics(created, { failOnNewMesh = 1 }),
  })
  local err = Assert.throws(function()
    p:acquire(0)
  end)
  Assert.isTrue(tostring(err):find("injected newMesh failure", 1, true) ~= nil)
  Assert.equal(#created, 1)
  Assert.isTrue(created[1].released, "the atlas acquired before mesh construction must be released")
  Assert.equal(p:stats().live, 0)
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.rejects_an_uncompiled_sprite()
  local p = provider({ 0 })
  throwsCode("FIELD_ACTOR_SPRITE_NOT_COMPILED", function()
    p:acquire(1032)
  end)
end

function T.rejects_unbalanced_release()
  local p = provider({ 0 })
  throwsCode("FIELD_ACTOR_RELEASE_UNKNOWN", function()
    p:release(0)
  end)
  p:acquire(0)
  p:release(0)
  throwsCode("FIELD_ACTOR_RELEASE_UNBALANCED", function()
    p:release(0)
  end)
end

function T.missing_artifacts_are_fatal()
  local cache = seed({ 0 })
  cache:remove(FieldActorCache.atlasPath(0))
  local p = FieldActorAssetProvider.new(cache, { graphics = stubGraphics({}) })
  throwsCode("FIELD_ACTOR_ATLAS_MISSING", function()
    p:acquire(0)
  end)

  local other = seed({ 0 })
  other:remove(FieldActorCache.visualPath(0))
  local q = FieldActorAssetProvider.new(other, { graphics = stubGraphics({}) })
  throwsCode("FIELD_ACTOR_VISUAL_UNAVAILABLE", function()
    q:acquire(0)
  end)
end

function T.rejects_a_cache_without_an_index()
  throwsCode("FIELD_ACTOR_INDEX_UNAVAILABLE", function()
    FieldActorAssetProvider.new(CacheFs.forVersion("heartgold", FakeCache.new()), {})
  end)
end

return { tests = T }
