-- Definition-provider tests keep runtime actor composition independent of GPU
-- resources while preserving the manager's acquire/release ownership contract.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local FieldActorDefinitionProvider = require("libs.engine.src.FieldActorDefinitionProvider")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local function cache()
  local result = CacheFs.forVersion("heartgold", FakeCache.new())
  result:writeLua(FieldActorCache.indexPath(), {
    schema = FieldActorCache.INDEX_SCHEMA,
    romVersion = "heartgold",
    spriteIds = { 0 },
    variableSprites = {},
    recordCount = 1,
  })
  result:writeLua(FieldActorCache.visualPath(0), FieldActorFixture.visual(0, { frameCount = 2 }))
  return result
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.loads_and_shares_actor_definitions_without_an_atlas()
  local provider = FieldActorDefinitionProvider.new(cache())
  local first = provider:acquire(0)
  local second = provider:acquire(0)
  Assert.isTrue(first == second, "runtime clients share one definition entry")
  Assert.equal(first.visual.spriteId, 0)
end

function T.releases_the_definition_after_its_last_owner()
  local provider = FieldActorDefinitionProvider.new(cache())
  local first = provider:acquire(0)
  provider:release(0)
  local second = provider:acquire(0)
  Assert.isTrue(first ~= second, "a released runtime definition is no longer resident")
  provider:release(0)
  throwsCode("FIELD_ACTOR_RELEASE_UNKNOWN", function()
    provider:release(0)
  end)
end

return T
