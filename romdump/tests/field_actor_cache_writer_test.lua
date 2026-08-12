-- Marker-last transaction tests for the field-actor cache writer, against an
-- in-memory cache and a synthetic bundle. Covers readiness, rollback on a failed
-- write, and the incomplete-bundle rejection.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldActorCacheWriter = require("romdump.src.digest.FieldActorCacheWriter")

local T = {}

local function visual(spriteId)
  return {
    schema = FieldActorCache.SCHEMA,
    spriteId = spriteId,
    mapModelId = 25,
    rawGraphicsFlags = 0,
    original = { movementProfile = 0, actorFamily = 0, visualDescriptor = 0 },
    render = {
      kind = "atlas",
      image = FieldActorCache.atlasPath(spriteId),
      frameWidth = 2,
      frameHeight = 1,
      frameCount = 2,
      billboardMode = "cameraFacingFull",
      mirrorEastWest = false,
    },
    frames = { { textureSlot = 0, paletteSlot = 0 }, { textureSlot = 1, paletteSlot = 0 } },
    directions = {},
  }
end

local function bundle(spriteIds)
  local visuals, atlases = {}, {}
  for _, spriteId in ipairs(spriteIds) do
    visuals[spriteId] = visual(spriteId)
    atlases[spriteId] = { width = 4, height = 1, pixels = string.rep("\0", 16) }
  end
  return {
    marker = FieldActorCache.marker("abc", "dep"),
    index = {
      schema = FieldActorCache.INDEX_SCHEMA,
      romVersion = "heartgold",
      spriteIds = spriteIds,
      variableSprites = {},
      recordCount = 3,
    },
    visuals = visuals,
    atlases = atlases,
    provenance = { schema = "g4-field-actor-provenance-v1" },
    dependencies = {},
  }
end

function T.writes_visuals_atlases_and_marker()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0, 29 })
  Assert.equal(FieldActorCacheWriter.write(cache, b), b.marker)
  Assert.isTrue(FieldActorCache.isReady(cache, b.marker), "ready after write")
  Assert.isTrue(cache:exists(FieldActorCache.atlasPath(29), "file"))
  Assert.equal(cache:loadLua(FieldActorCache.visualPath(0)).spriteId, 0)
end

function T.is_not_ready_for_a_different_marker()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0 })
  FieldActorCacheWriter.write(cache, b)
  Assert.isFalse(FieldActorCache.isReady(cache, "field-actor-cache-v1:abc:other"))
end

function T.is_not_ready_when_an_atlas_is_missing()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0, 29 })
  FieldActorCacheWriter.write(cache, b)
  cache:remove(FieldActorCache.atlasPath(29))
  Assert.isFalse(FieldActorCache.isReady(cache, b.marker))
end

function T.rejects_a_bundle_missing_an_indexed_sprite()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local b = bundle({ 0 })
  b.index.spriteIds = { 0, 99 }
  local err = Assert.throws(function()
    FieldActorCacheWriter.write(cache, b)
  end)
  Assert.isTrue(Errors.is(err), "expected an Errors object")
  Assert.equal(err.code, "FIELD_ACTOR_BUNDLE_INCOMPLETE")
  Assert.isNil(cache:read(FieldActorCache.markerPath()))
end

function T.rolls_back_the_actor_subtree_on_a_failed_write()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local original = backend.write
  ---@diagnostic disable: duplicate-set-field
  backend.write = function(self, path, data)
    if path:find("0029.png", 1, true) then
      error("injected write failure")
    end
    return original(self, path, data)
  end
  Assert.throws(function()
    FieldActorCacheWriter.write(cache, bundle({ 0, 29 }))
  end)
  Assert.isNil(cache:read(FieldActorCache.markerPath()))
  Assert.isFalse(cache:exists(FieldActorCache.visualPath(0), "file"), "a partial build leaves no visual behind")
end

function T.failed_rebuild_preserves_the_previous_artifact()
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  local first = bundle({ 0, 29 })
  FieldActorCacheWriter.write(cache, first)
  local original = backend.write
  ---@diagnostic disable: duplicate-set-field
  backend.write = function(self, path, data)
    if path:find("visuals/0029.lua", 1, true) then
      error("injected write failure")
    end
    return original(self, path, data)
  end
  local second = bundle({ 0, 29 })
  second.marker = FieldActorCache.marker("abc", "new-dep")
  Assert.throws(function()
    FieldActorCacheWriter.write(cache, second)
  end)
  Assert.isTrue(FieldActorCache.isReady(cache, first.marker), "the previous artifact remains ready")
  Assert.equal(cache:loadLua(FieldActorCache.visualPath(29)).spriteId, 29)
  Assert.equal(cache:read(FieldActorCache.markerPath()), first.marker, "the new marker never reached the live tree")
  Assert.isNil(backend:getInfo("staging/heartgold/field-actors"), "the stage is cleaned on failure")
  backend.write = original
  FieldActorCacheWriter.write(cache, second)
  Assert.isTrue(FieldActorCache.isReady(cache, second.marker), "a successful retry publishes the new artifact")
  Assert.isNil(backend:getInfo("staging/heartgold/field-actors"), "the stage is cleaned on success")
end

return T
