-- Contract scenarios for strict validation of the generated Oak intro class.
-- These fixtures model the public schema only; ROM identities belong to the
-- producer provenance and are intentionally absent here.

local Assert = require("tests.support.Assert")
local DerivedAssetContract = require("libs.assets.src.DerivedAssetContract")

local T = {}
local WIDGETS = { "ball_open", "female", "male", "marill", "oak", "shrink_female", "shrink_male" }

local function frame(path, width, height, duration)
  return { image = path, width = width, height = height, duration = duration }
end

local function validManifest()
  local widgets = {}
  for _, id in ipairs(WIDGETS) do
    local path = "assets/generated/intro/" .. id .. ".png"
    widgets[id] = {
      image = path,
      width = 32,
      height = 32,
      anchor = { x = 16, y = 32 },
      sourceBounds = { x = 0, y = 0, width = 32, height = 32 },
      sampling = "nearest",
      provenance = { rule = "alpha-crop" },
      frames = { frame(path, 32, 32, 4) },
    }
  end
  widgets.ball_open.sourceCenter = { x = 128, y = 90 }
  widgets.ball_open.frames = {
    frame("assets/generated/intro/ball-open-0.png", 32, 32, 1),
    frame("assets/generated/intro/ball-open-1.png", 32, 32, 4),
  }
  return {
    schemaVersion = 2,
    variant = "heartgold",
    sourceReference = { width = 256, height = 192 },
    background = {
      image = "assets/generated/intro/background.png",
      width = 1,
      height = 192,
      sampling = "linear",
      provenance = { charMember = 0, screenMember = 3, paletteMember = 1 },
    },
    widgets = widgets,
  }
end

local function reject(cache, mutate, label)
  local manifest = validManifest()
  mutate(manifest)
  local ok, err = cache.validateManifest(manifest)
  Assert.isFalse(ok, label .. " must be rejected")
  Assert.equal(assert(err).code, "INTRO_MANIFEST_INVALID", label .. " has a typed error")
end

function T.complete_schema_two_manifest_loads_and_declares_closed_inventory()
  local cache = require("libs.assets.src.IntroAssetCache")
  Assert.equal(cache.SCHEMA, "g4-intro-assets-v2")
  Assert.equal(cache.FORMAT, DerivedAssetContract.intro.cacheFormat)
  local manifest = validManifest()
  Assert.isTrue(cache.validateManifest(manifest))
  Assert.keySet(manifest.widgets, "ball_open,female,male,marill,oak,shrink_female,shrink_male")
end

function T.stale_and_malformed_manifests_fail_before_composition()
  local cache = require("libs.assets.src.IntroAssetCache")
  Assert.isTrue(cache.validateManifest(validManifest()), "the complete schema-2 fixture must be accepted first")
  reject(cache, function(manifest)
    manifest.schemaVersion = 1
  end, "stale schema")
  reject(cache, function(manifest)
    manifest.widgets.ball_open = nil
  end, "missing widget")
  reject(cache, function(manifest)
    manifest.widgets.ball = validManifest().widgets.oak
  end, "unknown widget")
  reject(cache, function(manifest)
    manifest.widgets.oak.anchor.x = 33
  end, "invalid anchor")
  reject(cache, function(manifest)
    manifest.widgets.ball_open.frames[2].width = 31
  end, "inconsistent animation")
  reject(cache, function(manifest)
    manifest.background.width = 2
  end, "incorrect gradient dimensions")
  reject(cache, function(manifest)
    manifest.variant = "unknown"
  end, "invalid variant")
end

return { tests = T }
