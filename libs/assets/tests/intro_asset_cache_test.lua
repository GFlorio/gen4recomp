-- The consumer-facing contract for the generated Professor Oak/profile visual
-- class: one semantic manifest, strict payload references, source-independent
-- records, and a completion marker that is visible only for a complete class.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")
local FakeCache = require("tests.support.FakeCache")

local T = {}

local REQUIRED = {
  "background",
  "oak",
  "marill",
  "gender.male",
  "gender.female",
  "gender.indicator",
  "shrink.male",
  "shrink.female",
}

local function introCache()
  local ok, cache = pcall(require, "libs.assets.src.IntroAssetCache")
  if not ok then
    error("the intro visual cache contract is missing: " .. tostring(cache), 0)
  end
  Assert.notNil(DerivedAssetContract.intro, "the derived asset contract must declare the intro class")
  return cache
end

local function rect(x, y, width, height, duration)
  return { x = x, y = y, width = width, height = height, duration = duration }
end

local function validManifest(cache)
  local manifest = {
    schema = cache.SCHEMA,
    reference = { width = 256, height = 192, filter = "nearest" },
    assets = {},
  }
  local sizes = {
    background = { 256, 192 },
    oak = { 128, 128 },
    marill = { 64, 64 },
    ["gender.male"] = { 64, 64 },
    ["gender.female"] = { 64, 64 },
    ["gender.indicator"] = { 32, 16 },
    ["shrink.male"] = { 128, 128 },
    ["shrink.female"] = { 128, 128 },
  }
  for _, id in ipairs(REQUIRED) do
    local size = sizes[id]
    manifest.assets[id] = {
      image = "assets/generated/intro/" .. id:gsub("%.", "-") .. ".png",
      width = size[1],
      height = size[2],
      frames = { rect(0, 0, size[1], size[2], 1) },
      filter = "nearest",
    }
  end
  manifest.assets.oak.frames = { rect(0, 0, 64, 64, 6), rect(64, 0, 64, 64, 6) }
  manifest.assets["gender.indicator"].frames = { rect(0, 0, 16, 16, 4), rect(16, 0, 16, 16, 4) }
  manifest.assets["shrink.male"].frames = {
    rect(0, 0, 32, 32, 4),
    rect(32, 0, 32, 32, 4),
    rect(64, 0, 32, 32, 4),
    rect(96, 0, 32, 32, 4),
  }
  manifest.assets["shrink.female"].frames = {
    rect(0, 0, 32, 32, 4),
    rect(32, 0, 32, 32, 4),
    rect(64, 0, 32, 32, 4),
    rect(96, 0, 32, 32, 4),
  }
  return manifest
end

local function reject(cache, mutate)
  local manifest = validManifest(cache)
  mutate(manifest)
  local ok, err = cache.validateManifest(manifest)
  Assert.isFalse(ok, "malformed intro metadata must not validate")
  Assert.equal(assert(err).code, "INTRO_MANIFEST_INVALID")
end

function T.contract_declares_a_distinct_intro_class()
  local cache = introCache()
  Assert.equal(cache.FORMAT, DerivedAssetContract.intro.cacheFormat)
  Assert.equal(cache.SCHEMA, DerivedAssetContract.intro.schema)
  Assert.isTrue(cache.FORMAT ~= DerivedAssetContract.fieldUi.cacheFormat)
  Assert.equal(cache.marker("rom-sha", "dep-hash"), "intro-cache-v1:rom-sha:dep-hash")
end

function T.required_semantic_records_and_frame_metadata_are_closed()
  local cache = introCache()
  local manifest = validManifest(cache)
  Assert.isTrue(cache.validateManifest(manifest))
  for _, id in ipairs(REQUIRED) do
    local record = manifest.assets[id]
    Assert.notNil(record, "required intro resource " .. id)
    Assert.equal(record.filter, "nearest", id .. " keeps native filtering intent")
    Assert.isTrue(#record.frames >= 1, id .. " carries at least one frame")
    for _, frame in ipairs(record.frames) do
      Assert.isTrue(frame.width > 0 and frame.height > 0, id .. " frame has positive dimensions")
      Assert.isTrue(frame.duration > 0, id .. " frame has source timing")
      Assert.isTrue(frame.x + frame.width <= record.width, id .. " frame stays inside its payload")
      Assert.isTrue(frame.y + frame.height <= record.height, id .. " frame stays inside its payload")
    end
  end
end

function T.missing_unknown_and_unreferenced_payloads_are_not_ready()
  local cache = introCache()
  reject(cache, function(manifest)
    manifest.assets.marill = nil
  end)
  reject(cache, function(manifest)
    manifest.assets.tutorial = manifest.assets.oak
  end)
  reject(cache, function(manifest)
    manifest.assets.oak.frames[1].width = 129
  end)

  local manifest = validManifest(cache)
  local fs = CacheFs.forVersion("heartgold", FakeCache.new())
  fs:writeLua(cache.manifestPath(), manifest)
  fs:writeLua(cache.provenancePath(), {
    schema = cache.PROVENANCE_SCHEMA,
    source = { repo = "fixture", commit = "fixture", sources = { "fixture" } },
    dependencies = {},
  })
  fs:write(cache.markerPath(), cache.marker("rom-sha", "dep-hash"))
  for _, record in pairs(manifest.assets) do
    fs:write(record.image, "png")
  end
  Assert.isTrue(cache.isReady(fs, cache.marker("rom-sha", "dep-hash")))
  fs:remove(cache.provenancePath())
  Assert.isFalse(cache.isReady(fs, cache.marker("rom-sha", "dep-hash")))
  fs:remove(manifest.assets.marill.image)
  Assert.isFalse(cache.isReady(fs, cache.marker("rom-sha", "dep-hash")))
end

return { tests = T }
