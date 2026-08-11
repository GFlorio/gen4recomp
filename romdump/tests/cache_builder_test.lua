-- CacheBuilder contract: per-version derived-cache compilation with the
-- machine-readable build-cache log, compile-exclusion handling, and
-- per-version failure continuation. The digest and cache modules are faked
-- through package.loaded before CacheBuilder is required, so the pipeline is
-- exercised without a ROM or filesystem.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")

-- Every module CacheBuilder requires at load; each is replaced with a fake.
local FAKE_PATHS = {
  "libs.rom.src.RomFs",
  "libs.rom.src.CacheFs",
  "romdump.src.digest.MapAnalysis",
  "romdump.src.digest.MapAssetCompiler",
  "romdump.src.digest.MapCacheWriter",
  "libs.assets.src.MapAssetCache",
  "romdump.src.digest.WorldManifest",
  "romdump.src.digest.FieldCameraCompiler",
  "romdump.src.digest.FieldCameraCacheWriter",
  "romdump.src.digest.FieldMapDataCompiler",
  "romdump.src.digest.FieldMapDataCacheWriter",
  "libs.assets.src.FieldMapDataCache",
  "romdump.src.digest.FieldActorCompiler",
  "romdump.src.digest.FieldActorCacheWriter",
  "romdump.src.digest.FieldMessageCompiler",
  "romdump.src.digest.FieldMessageCacheWriter",
  "libs.assets.src.FieldMessageCache",
  "romdump.src.digest.FieldFontCompiler",
  "romdump.src.digest.FieldFontCacheWriter",
  "libs.assets.src.FieldFontCache",
  "romdump.src.digest.script.ScriptCompiler",
  "romdump.src.digest.ScriptCacheWriter",
  "libs.assets.src.ScriptCache",
}

local T = {}

local saved = {}
local env
local CacheBuilder

-- One shared environment drives every fake; tests swap in fresh state per test.
local function newEnv()
  return {
    stale = {},
    openFailures = {},
    failCompilers = {},
    compileFailures = {},
    calls = {},
    opens = {},
    closes = {},
    manifest = nil,
    mapResults = {
      {
        status = "resolved",
        id = 2,
        symbol = "s_town",
        matrixMemberId = 1,
        matrixX = 0,
        matrixZ = 1,
        matrixIndex = 2,
        landDataMemberId = 3,
        source = "direct",
        matchCount = 1,
      },
      {
        status = "resolved",
        id = 5,
        symbol = "s_route",
        matrixMemberId = 6,
        matrixX = 2,
        matrixZ = 3,
        matrixIndex = 4,
        landDataMemberId = 5,
        source = "matrix",
        matchCount = 2,
      },
    },
    mapBundles = {
      [2] = {
        mapId = 2,
        marker = "m2",
        scene = { mapSymbol = "s_town", matrix = { width = 20, height = 20 } },
        unresolvedMaterials = {},
      },
      [5] = {
        mapId = 5,
        marker = "m5",
        scene = { mapSymbol = "s_route", matrix = { width = 10, height = 10 } },
        unresolvedMaterials = {
          {
            role = "map",
            kind = "texture",
            material = "bike_02_2_lm3",
            modelName = "m_name01_00_00c",
            modelArchive = "land_data",
            modelMemberId = 280,
            name = "bike_02_2",
            source = "map_textures member 42",
          },
        },
      },
    },
    cameraBundle = { marker = "cam-v1" },
    actorBundle = { marker = "act-v1", index = { spriteIds = { 0, 1, 2 } } },
    fieldBundles = {
      { mapId = 3, marker = "fd-3" },
      { mapId = 7, marker = "fd-7" },
    },
    fontBundle = { fontId = 5, marker = "font-v1" },
    messageBundle = { marker = "msg-v1", index = { bankIds = { 4, 8 } } },
    scriptBundle = { marker = "scr-v1", index = { resourceCount = 2, scriptMemberCount = 9 } },
  }
end

local function makeFakes()
  local fakes = {}
  for _, path in ipairs(FAKE_PATHS) do
    local name = path:match("([^%.]+)$")
    local m = {}
    -- isReady is the stale gate shared by every cache class; write records.
    m.isReady = function()
      return not env.stale[name]
    end
    m.write = function()
      env.calls[#env.calls + 1] = name .. ".write"
    end
    fakes[name] = m
  end

  fakes.RomFs.open = function(version)
    if env.openFailures[version] ~= nil then
      return nil, env.openFailures[version]
    end
    env.opens[#env.opens + 1] = version
    return {
      version = version,
      close = function()
        env.closes[#env.closes + 1] = version
      end,
    }
  end
  fakes.CacheFs.forVersion = function(version)
    env.calls[#env.calls + 1] = "CacheFs.forVersion:" .. version
    return { version = version }
  end
  fakes.MapAnalysis.analyze = function()
    return env.mapResults
  end
  fakes.MapAssetCompiler.compile = function(_, mapId)
    if env.compileFailures[mapId] ~= nil then
      return nil, env.compileFailures[mapId]
    end
    return env.mapBundles[mapId]
  end
  fakes.FieldCameraCompiler.compile = function(romFs)
    if env.failCompilers[romFs.version] ~= nil then
      error(env.failCompilers[romFs.version], 0)
    end
    return env.cameraBundle
  end
  fakes.FieldActorCompiler.compile = function()
    return env.actorBundle
  end
  fakes.FieldMapDataCompiler.compileAll = function()
    return env.fieldBundles
  end
  fakes.FieldFontCompiler.compile = function()
    return env.fontBundle
  end
  fakes.FieldMessageCompiler.compile = function()
    return env.messageBundle
  end
  fakes.ScriptCompiler.compile = function()
    return env.scriptBundle
  end
  fakes.WorldManifest.write = function(_, entries, excluded, compileExcluded)
    env.calls[#env.calls + 1] = "WorldManifest.write"
    env.manifest = { entries = entries, excluded = excluded, compileExcluded = compileExcluded }
  end
  return fakes
end

local function collectLog()
  local lines = {}
  return {
    lines = lines,
    log = function(line)
      lines[#lines + 1] = line
    end,
  }
end

local module = {
  beforeAll = function()
    for _, path in ipairs(FAKE_PATHS) do
      saved[path] = package.loaded[path]
      package.loaded[path] = nil
    end
    env = newEnv()
    local fakes = makeFakes()
    for _, path in ipairs(FAKE_PATHS) do
      package.loaded[path] = fakes[path:match("([^%.]+)$")]
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
    CacheBuilder = require("romdump.src.CacheBuilder")
  end,
  afterAll = function()
    for _, path in ipairs(FAKE_PATHS) do
      package.loaded[path] = saved[path]
    end
    package.loaded["romdump.src.CacheBuilder"] = nil
  end,
  tests = T,
}

-- Every current class is logged in pipeline order, the world manifest receives
-- the resolved map records, and the report says the cache is current.
function T.current_build_logs_every_class_and_writes_the_world_manifest()
  env = newEnv()
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(err)
  Assert.deepEqual(report, { current = true })
  Assert.deepEqual(capture.lines, {
    "build-cache: heartgold field cameras current",
    "build-cache: heartgold field actors current",
    "build-cache: heartgold map 3 field data current",
    "build-cache: heartgold map 7 field data current",
    "build-cache: heartgold field font current",
    "build-cache: heartgold field messages current",
    "build-cache: heartgold scripts current",
    "build-cache: heartgold map 2 current",
    "build-cache: heartgold map 5 current",
    "build-cache: heartgold map 5 unresolved map texture: material bike_02_2_lm3 of m_name01_00_00c land_data:280 wants bike_02_2 from map_textures member 42",
    "build-cache: heartgold world.lua written (2 maps, 0 unresolved cells, 0 compile-excluded)",
  })
  Assert.deepEqual(env.manifest.entries, {
    {
      id = 2,
      symbol = "s_town",
      width = 20,
      height = 20,
      matrix = { memberId = 1, x = 0, z = 1, index = 2, landDataMemberId = 3, selection = "direct", matchCount = 1 },
    },
    {
      id = 5,
      symbol = "s_route",
      width = 10,
      height = 10,
      matrix = { memberId = 6, x = 2, z = 3, index = 4, landDataMemberId = 5, selection = "matrix", matchCount = 2 },
    },
  })
end

-- A stale class is compiled through its writer and logged with its counts;
-- writer order follows the class order of the pipeline.
function T.stale_classes_compile_with_counts_in_pipeline_order()
  env = newEnv()
  env.stale = {
    FieldCameraCacheWriter = true,
    FieldActorCacheWriter = true,
    FieldMapDataCache = true,
    FieldFontCacheWriter = true,
    FieldMessageCacheWriter = true,
    ScriptCacheWriter = true,
    MapAssetCache = true,
  }
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(err)
  Assert.deepEqual(report, { current = true })
  Assert.deepEqual(capture.lines, {
    "build-cache: heartgold field cameras compiled",
    "build-cache: heartgold field actors compiled (3 sprites)",
    "build-cache: heartgold map 3 field data compiled",
    "build-cache: heartgold map 7 field data compiled",
    "build-cache: heartgold field font compiled",
    "build-cache: heartgold field messages compiled (2 banks)",
    "build-cache: heartgold scripts compiled (2 resources, 9 members)",
    "build-cache: heartgold map 2 compiled",
    "build-cache: heartgold map 5 compiled",
    "build-cache: heartgold map 5 unresolved map texture: material bike_02_2_lm3 of m_name01_00_00c land_data:280 wants bike_02_2 from map_textures member 42",
    "build-cache: heartgold world.lua written (2 maps, 0 unresolved cells, 0 compile-excluded)",
  })
  Assert.deepEqual(env.calls, {
    "CacheFs.forVersion:heartgold",
    "FieldCameraCacheWriter.write",
    "FieldActorCacheWriter.write",
    "FieldMapDataCacheWriter.write",
    "FieldMapDataCacheWriter.write",
    "FieldFontCacheWriter.write",
    "FieldMessageCacheWriter.write",
    "ScriptCacheWriter.write",
    "MapCacheWriter.write",
    "MapCacheWriter.write",
    "WorldManifest.write",
  })
end

-- A structured compile rejection is recorded in the manifest, logged, and
-- fails the build unless the caller accepts compile exclusions.
function T.compile_exclusions_fail_the_build_unless_allowed()
  env = newEnv()
  env.compileFailures[5] = Errors.new("MAP_SCHEMA_INVALID", "injected compile rejection")
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold" }, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(capture.lines[8], "build-cache: heartgold map 2 current")
  Assert.equal(
    capture.lines[9],
    "build-cache: heartgold map 5 excluded: MAP_SCHEMA_INVALID: injected compile rejection"
  )
  Assert.deepEqual(env.manifest.compileExcluded, {
    {
      id = 5,
      symbol = "s_route",
      errorCode = "MAP_SCHEMA_INVALID",
      message = "injected compile rejection",
      context = {},
    },
  })
  Assert.equal(
    capture.lines[11],
    "build-cache: compile exclusions remain; " .. "rerun with --allow-compile-exclusions to accept them"
  )

  local accepted = collectLog()
  local report2, err2 = CacheBuilder.buildVersions(
    { "heartgold" },
    { allowCompileExclusions = true, log = accepted.log }
  )
  Assert.isNil(err2)
  Assert.deepEqual(report2, { current = true })
  Assert.equal(
    accepted.lines[10],
    "build-cache: heartgold world.lua written (1 maps, 0 unresolved cells, 1 compile-excluded)"
  )
end

-- One broken version is reported, its RomFs handle is still closed, and the
-- remaining versions run to completion.
function T.a_failed_version_continues_and_closes_its_romfs()
  env = newEnv()
  env.failCompilers.heartgold = "boom"
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold", "soulsilver" }, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.equal(capture.lines[1], "build-cache: heartgold failed: boom")
  Assert.equal(capture.lines[2], "build-cache: soulsilver field cameras current")
  Assert.deepEqual(env.closes, { "heartgold", "soulsilver" })
end

-- An open failure is logged like any per-version failure, closes nothing, and
-- does not stop the remaining versions.
function T.open_failure_is_reported_and_closes_nothing()
  env = newEnv()
  env.openFailures.heartgold = "injected open failure"
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({ "heartgold", "soulsilver" }, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "cache preparation failed")
  Assert.isTrue(capture.lines[1]:find("injected open failure", 1, true) ~= nil, capture.lines[1])
  Assert.equal(capture.lines[2], "build-cache: soulsilver field cameras current")
  Assert.deepEqual(env.opens, { "soulsilver" })
  Assert.deepEqual(env.closes, { "soulsilver" })
end

-- An empty version list is part of the function contract: no build runs and
-- the caller-facing error names the empty selection.
function T.empty_version_list_returns_no_ready_version_to_compile()
  env = newEnv()
  local capture = collectLog()
  local report, err = CacheBuilder.buildVersions({}, { log = capture.log })
  Assert.isNil(report)
  Assert.equal(err, "no ready version to compile")
  Assert.deepEqual(capture.lines, { "build: no ready version to compile" })
end

-- The log option defaults to print, the plain-Lua output of the CLI.
function T.log_defaults_to_print()
  env = newEnv()
  local lines = {}
  local realPrint = print
  _G.print = function(line)
    lines[#lines + 1] = tostring(line)
  end
  local ok, report, err = pcall(CacheBuilder.buildVersions, { "heartgold" })
  _G.print = realPrint
  Assert.isTrue(ok, tostring(report))
  Assert.equal(err, nil)
  Assert.deepEqual(report, { current = true })
  Assert.equal(lines[1], "build-cache: heartgold field cameras current")
end

return module
