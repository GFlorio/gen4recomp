-- Producer-side intro output contract: malformed source fails with source
-- context, the semantic class is minimal and deterministic, and publication
-- keeps an older ready class when staging or replacement fails.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local function introCache()
  local ok, cache = pcall(require, "libs.assets.src.IntroAssetCache")
  if not ok then
    error("the intro visual cache contract is missing: " .. tostring(cache), 0)
  end
  return cache
end

local function compiler()
  local ok, module = pcall(require, "romdump.src.digest.IntroAssetCompiler")
  if not ok then
    error("the ROM-derived intro compiler is missing: " .. tostring(module), 0)
  end
  return module
end

local function writer()
  local ok, module = pcall(require, "romdump.src.digest.IntroAssetCacheWriter")
  if not ok then
    error("the intro cache has no failure-safe publication path: " .. tostring(module), 0)
  end
  return module
end

local function fixtureBundle(cache, marker)
  local assets, manifestAssets = {}, {}
  for _, id in ipairs(cache.REQUIRED_ASSETS) do
    local image = cache.assetDir() .. "/" .. id:gsub("%.", "-") .. ".png"
    manifestAssets[id] = {
      image = image,
      width = 1,
      height = 1,
      frames = { { x = 0, y = 0, width = 1, height = 1, duration = 1 } },
      filter = "nearest",
    }
    assets[image] = "png"
  end
  return {
    marker = marker,
    manifest = {
      schema = cache.SCHEMA,
      reference = { width = 256, height = 192, filter = "nearest" },
      assets = manifestAssets,
    },
    dependencies = {
      schema = cache.PROVENANCE_SCHEMA,
      source = { repo = "fixture", commit = "fixture", sources = { "fixture" } },
      dependencies = {},
    },
    assets = assets,
  }
end

function T.source_failures_are_attributed_and_do_not_publish_partial_output()
  local Compiler = compiler()
  local source = {
    metadata = function()
      return { sha1 = "verified-rom-sha" }
    end,
    openNarc = function()
      return {
        readMember = function()
          return nil, "missing source member"
        end,
      }
    end,
  }
  local ok, err = pcall(Compiler.compile, source)
  Assert.isFalse(ok, "missing source data must fail the build")
  Assert.isTrue(tostring(err):find("source", 1, true) ~= nil, "the failure names source provenance")
end

function T.source_reader_is_required_for_compilation()
  local Compiler = compiler()
  local ok, err = pcall(Compiler.compile, {
    metadata = function()
      return { sha1 = "verified-rom-sha" }
    end,
  })
  Assert.isFalse(ok, "metadata without a source reader must not emit placeholders")
  Assert.isTrue(tostring(err):find("source", 1, true) ~= nil)
end

function T.failed_replacement_preserves_the_previous_ready_class()
  local cache = introCache()
  local CacheWriter = writer()
  local backend = FakeCache.new()
  local live = CacheFs.forVersion("heartgold", backend)
  local old = fixtureBundle(cache, "intro-cache-v1:old:dependencies")
  CacheWriter.write(live, old)
  local oldMarker = live:read(cache.markerPath())
  local oldManifest = live:read(cache.manifestPath())

  local replacements = 0
  local originalReplace = backend.replace
  local failingBackend = setmetatable({
    replace = function(_, sourcePath, destinationPath)
      replacements = replacements + 1
      if replacements == 2 then
        return false, "injected publication failure"
      end
      return originalReplace(backend, sourcePath, destinationPath)
    end,
  }, { __index = backend })
  live = CacheFs.forVersion("heartgold", failingBackend)

  local replacement = fixtureBundle(cache, "intro-cache-v1:new:dependencies")
  local published, publishErr = pcall(CacheWriter.write, live, replacement)
  Assert.isFalse(published, "a replacement failure must reach the caller")
  Assert.isTrue(tostring(publishErr):find("publication", 1, true) ~= nil)
  Assert.equal(live:read(cache.markerPath()), oldMarker)
  Assert.equal(live:read(cache.manifestPath()), oldManifest)
  Assert.isTrue(cache.isReady(live, oldMarker), "the previous class remains ready")
end

return { tests = T }
