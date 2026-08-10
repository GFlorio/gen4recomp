-- Runner build-pipeline regression for incremental actor-cache builds. The
-- pipeline's actor step runs for real (Runner._runBuild) against a FakeCache;
-- only the ROM-facing compilers are stubbed, so the second build's readiness
-- decision and the actor writer are the actual production code. An unchanged
-- second build must hit the actor "current" path and perform no actor rewrite.

local Assert = require("tests.support.Assert")
local Runner = require("romdump.src.cli.Runner")
local CacheFs = require("libs.rom.src.CacheFs")
local RomImporter = require("libs.rom.src.RomImporter")
local RomFs = require("libs.rom.src.RomFs")
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

local function actorBundle()
  local visuals, atlases = {}, {}
  for _, spriteId in ipairs({ 0, 29 }) do
    visuals[spriteId] = visual(spriteId)
    atlases[spriteId] = { width = 4, height = 1, pixels = string.rep("\0", 16) }
  end
  return {
    marker = FieldActorCache.marker("romsha", "dep"),
    index = {
      schema = FieldActorCache.INDEX_SCHEMA,
      romVersion = "heartgold",
      spriteIds = { 0, 29 },
      variableSprites = {},
      recordCount = 2,
    },
    visuals = visuals,
    atlases = atlases,
    provenance = { schema = "g4-field-actor-provenance-v1" },
    dependencies = {},
  }
end

-- Run fn with the ROM side of Runner._runBuild stubbed out and restore every
-- stub afterwards, so a failing assertion cannot leak state into later tests.
local function withStubbedPipeline(fn)
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  local bundle = actorBundle()

  local savedLoaded, loaded = {}, package.loaded
  local function stub(name, value)
    if loaded[name] ~= nil then
      savedLoaded[name] = loaded[name]
    else
      savedLoaded[name] = false -- sentinel: the module was absent and must be nil'd on restore
    end
    loaded[name] = value
  end
  local moduleStubs = {
    ["romdump.src.digest.FieldActorCompiler"] = {
      compile = function()
        return bundle
      end,
    },
    ["romdump.src.digest.FieldCameraCompiler"] = {
      compile = function()
        return { marker = "cam" }
      end,
    },
    ["romdump.src.digest.FieldCameraCacheWriter"] = {
      isReady = function()
        return true
      end,
    },
    ["romdump.src.digest.FieldMapDataCompiler"] = {
      compileAll = function()
        return {}
      end,
    },
    ["romdump.src.digest.FieldFontCompiler"] = {
      compile = function()
        return { fontId = 0, marker = "font" }
      end,
    },
    ["romdump.src.digest.FieldFontCacheWriter"] = {
      isReady = function()
        return true
      end,
    },
    ["romdump.src.digest.FieldMessageCompiler"] = {
      compile = function()
        return { marker = "msg", index = { bankIds = {} } }
      end,
    },
    ["romdump.src.digest.FieldMessageCacheWriter"] = {
      isReady = function()
        return true
      end,
    },
    ["romdump.src.digest.script.ScriptCompiler"] = {
      compile = function()
        return { marker = "script", index = { resourceCount = 0, scriptMemberCount = 0 } }
      end,
    },
    ["romdump.src.digest.ScriptCacheWriter"] = {
      isReady = function()
        return true
      end,
    },
    ["romdump.src.digest.MapAnalysis"] = {
      analyze = function()
        return {}
      end,
    },
    ["romdump.src.digest.WorldManifest"] = { write = function() end },
  }
  for name, module in pairs(moduleStubs) do
    stub(name, module)
  end

  local realForVersion, realIsReady, realOpen, realQuit =
    CacheFs.forVersion, RomImporter.isReady, RomFs.open, love.event.quit
  ---@diagnostic disable: duplicate-set-field
  CacheFs.forVersion = function(id)
    assert(id == "heartgold", "pipeline must only build the stubbed version")
    return cache
  end
  RomImporter.isReady = function(id)
    return id == "heartgold"
  end
  RomFs.open = function()
    return { close = function() end }
  end
  ---@diagnostic disable: duplicate-set-field
  love.event.quit = function(...) end

  local function restore()
    for name, previous in pairs(savedLoaded) do
      if previous == false then
        loaded[name] = nil
      else
        loaded[name] = previous
      end
    end
    CacheFs.forVersion, RomImporter.isReady, RomFs.open = realForVersion, realIsReady, realOpen
    love.event.quit = realQuit
  end

  local ok, result = xpcall(function()
    fn(cache, bundle)
  end, debug.traceback)
  restore()
  if not ok then
    error(result, 0)
  end
end

-- Running the cache build twice with identical dependencies must take the
-- actor "current" path on the second run and perform no actor rewrite: the
-- build step must never invalidate the live actor roots before its readiness
-- check.
function T.unchanged_second_build_rewrites_nothing()
  withStubbedPipeline(function(cache, bundle)
    local backend = cache.backend
    local actorWrites = 0
    local originalWrite = backend.write
    ---@diagnostic disable: duplicate-set-field
    backend.write = function(self, path, data)
      if path:find("field/actors", 1, true) then
        actorWrites = actorWrites + 1
      end
      return originalWrite(self, path, data)
    end

    Runner._runBuild()
    local writesAfterFirst = actorWrites
    Assert.isTrue(writesAfterFirst > 0, "the first build must publish the actor artifact")
    Assert.isTrue(FieldActorCacheWriter.isReady(cache, bundle.marker), "first build publishes a ready artifact")

    Runner._runBuild()
    Assert.equal(actorWrites, writesAfterFirst, "an unchanged second build must not rewrite actor assets")
    Assert.isTrue(FieldActorCacheWriter.isReady(cache, bundle.marker), "the published artifact is still current")
    Assert.equal(cache:read(FieldActorCache.markerPath()), bundle.marker, "the live marker is untouched")
  end)
end

return T
