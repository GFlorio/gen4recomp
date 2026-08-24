-- Producer-side intro output contract: malformed source fails with source
-- context, the semantic class is minimal and deterministic, and publication
-- keeps an older ready class when staging or replacement fails.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")

local T = {}

function T.reveal_source_configuration_uses_resource_set_five_sequences_and_palettes()
  local config = require("romdump.src.config.IntroAssets")
  for id, sequence, palette in pairs({ ball_open = { 3, 5 }, marill_appear = { 1, 4 }, marill = { 2, 4 } }) do
    local entry = assert(config[id])
    Assert.equal(entry.archive, "intro")
    Assert.equal(entry.char, 64)
    Assert.equal(entry.palette, 63)
    Assert.equal(entry.cell, 65)
    Assert.equal(entry.animation, 66)
    Assert.equal(entry.animationIndex, sequence[1])
    Assert.equal(entry.paletteOverride, sequence[2])
    Assert.equal(entry.resourceSet, 5)
    Assert.deepEqual(entry.sourceCenter, { x = 160, y = 80 })
  end
end

function T.gender_selector_configuration_declares_animation_sources_and_centers()
  local config = require("romdump.src.config.IntroAssets")
  for id, expected in pairs({
    male = { resourceSet = 1, sourceCenter = { x = 64, y = 104 } },
    female = { resourceSet = 2, sourceCenter = { x = 192, y = 104 } },
  }) do
    local entry = assert(config.genderSelectors[id])
    Assert.equal(entry.animationIndex, 0)
    Assert.equal(entry.paletteOverride, 0)
    Assert.equal(entry.resourceSet, expected.resourceSet)
    Assert.deepEqual(entry.sourceCenter, expected.sourceCenter)
    Assert.equal(entry.resourceResolution, config.ball_open.resourceResolution)
  end
end

local function compiler()
  local ok, module = pcall(require, "romdump.src.digest.IntroAssetCompiler")
  if not ok then
    error("the ROM-derived intro compiler is missing: " .. tostring(module), 0)
  end
  return module
end

local function u32le(value)
  local bytes = {}
  for _ = 1, 4 do
    bytes[#bytes + 1] = string.char(value % 256)
    value = math.floor(value / 256)
  end
  return table.concat(bytes)
end

local function resdatTable(records)
  local bytes = { u32le(0) }
  for id = 0, records.count do
    local record = records[id] or { narcId = 120, fileId = id, id = id }
    bytes[#bytes + 1] = u32le(record.narcId)
    bytes[#bytes + 1] = u32le(record.fileId)
    bytes[#bytes + 1] = u32le(0)
    bytes[#bytes + 1] = u32le(record.id)
    bytes[#bytes + 1] = u32le(0)
    bytes[#bytes + 1] = u32le(0)
  end
  bytes[#bytes + 1] = u32le(0xFFFFFFFE)
  bytes[#bytes + 1] = u32le(0xFFFFFFFE)
  bytes[#bytes + 1] = u32le(0xFFFFFFFE)
  bytes[#bytes + 1] = u32le(0xFFFFFFFE)
  bytes[#bytes + 1] = u32le(0xFFFFFFFE)
  bytes[#bytes + 1] = u32le(0xFFFFFFFE)
  return table.concat(bytes)
end

local function selectorResourceTables()
  local header = {}
  for resourceSet = 0, 5 do
    local ids = ({
      [0] = { 2, 1, 1, 1 },
      [1] = { 4, 2, 2, 2 },
      [2] = { 5, 1, 2, 2 },
      [3] = { 6, 5, 3, 3 },
      [4] = { 7, 6, 4, 4 },
      [5] = { 8, 7, 5, 5 },
    })[resourceSet]
    for _, id in ipairs(ids) do
      header[#header + 1] = u32le(id)
    end
    for _ = 1, 2 do
      header[#header + 1] = u32le(0xFFFFFFFF)
    end
    header[#header + 1] = u32le(0)
    header[#header + 1] = u32le(0)
  end
  return {
    [78] = table.concat(header),
    [26] = resdatTable({
      count = 8,
      [4] = { narcId = 120, fileId = 12, id = 4 },
      [5] = { narcId = 120, fileId = 17, id = 5 },
      [8] = { narcId = 120, fileId = 64, id = 8 },
    }),
    [27] = resdatTable({
      count = 7,
      [1] = { narcId = 120, fileId = 11, id = 1 },
      [2] = { narcId = 120, fileId = 16, id = 2 },
      [7] = { narcId = 120, fileId = 63, id = 7 },
    }),
    [25] = resdatTable({
      count = 5,
      [2] = { narcId = 120, fileId = 55, id = 2 },
      [5] = { narcId = 120, fileId = 65, id = 5 },
    }),
    [24] = resdatTable({
      count = 5,
      [2] = { narcId = 120, fileId = 56, id = 2 },
      [5] = { narcId = 120, fileId = 66, id = 5 },
    }),
  }
end

local function syntheticCompilerSource()
  local decoder = require("romdump.src.digest.G2dDecoder")
  local original = {}
  for _, name in ipairs({ "decodeChar", "decodePalette", "decodeScreen", "decodeCell", "decodeAnimation" }) do
    original[name] = decoder[name]
  end
  local function restore()
    for name, value in pairs(original) do
      decoder[name] = value
    end
  end

  rawset(decoder, "decodeChar", function()
    local tiles = {}
    for tile = 0, 23 do
      tiles[#tiles + 1] = string.rep(string.char(tile % 15 + 1), 64)
    end
    return { depth = 4, tiles = table.concat(tiles) }
  end)
  rawset(decoder, "decodePalette", function()
    local colors = {}
    for index = 1, 16 do
      colors[index] = { r = index, g = index + 1, b = index + 2 }
    end
    return { colors = colors }
  end)
  rawset(decoder, "decodeScreen", function()
    local entries = {}
    for row = 0, 23 do
      entries[#entries + 1] = { tile = row, palette = 0, flipH = false, flipV = false }
    end
    return { width = 8, height = 192, entries = entries }
  end)
  rawset(decoder, "decodeCell", function()
    return {
      cells = {
        { objs = { { x = -8, y = -8, width = 8, height = 8, tile = 0, palette = 1 } } },
        { objs = { { x = 8, y = 8, width = 8, height = 8, tile = 0, palette = 1 } } },
      },
    }
  end)
  rawset(decoder, "decodeAnimation", function()
    local selected = { frames = { { cell = 0, duration = 2 }, { cell = 1, duration = 3 } } }
    return { anims = { selected, selected, selected, selected } }
  end)

  local archive
  local resourceTables = selectorResourceTables()
  archive = {
    reads = {},
    readMember = function(_, memberId)
      archive.reads[#archive.reads + 1] = memberId
      if resourceTables[memberId] then
        return resourceTables[memberId]
      end
      return string.char(0, memberId % 256)
    end,
  }
  local source = {
    metadata = function()
      return { sha1 = "synthetic-intro-source" }
    end,
    version = function()
      return "heartgold"
    end,
    openNarc = function()
      return archive
    end,
  }
  return source, restore, archive.reads
end

function T.gender_selectors_compile_their_configured_cell_animations()
  local Compiler = compiler()
  local source, restore, reads = syntheticCompilerSource()
  local ok, result = xpcall(function()
    return Compiler.compile(source)
  end, debug.traceback)
  restore()
  if not ok then
    error(result, 0)
  end

  for _, id in ipairs({ "gender_male", "gender_female" }) do
    local widget = result.manifest.widgets[id]
    Assert.equal(widget.width, 24)
    Assert.equal(widget.height, 24)
    Assert.notNil(widget.sourceCenter)
    Assert.isTrue(#widget.frames > 0)
  end
  local resolvedReads = {}
  for _, memberId in ipairs(reads) do
    resolvedReads[memberId] = true
  end
  Assert.isTrue(resolvedReads[12], "male selector char resolves through resource tables")
  Assert.isTrue(resolvedReads[16], "male selector palette resolves through resource tables")
  Assert.isTrue(resolvedReads[17], "female selector char resolves through resource tables")
  Assert.isTrue(resolvedReads[11], "female selector palette resolves through resource tables")
  Assert.isTrue(resolvedReads[55], "selector cell resolves through resource tables")
  Assert.isTrue(resolvedReads[56], "selector animation resolves through resource tables")
  local roles = {}
  for _, dependency in ipairs(result.dependencies.dependencies) do
    roles[dependency.role] = dependency.memberId
  end
  Assert.equal(roles["gender-male:char"], 12)
  Assert.equal(roles["gender-male:palette"], 16)
  Assert.equal(roles["gender-male:cell"], 55)
  Assert.equal(roles["gender-male:animation"], 56)
  Assert.equal(roles["gender-female:char"], 17)
  Assert.equal(roles["gender-female:palette"], 11)
  Assert.equal(roles["gender-female:cell"], 55)
  Assert.equal(roles["gender-female:animation"], 56)
end

function T.cell_animation_frames_preserve_one_source_origin()
  local Compiler = compiler()
  local source, restore = syntheticCompilerSource()
  local ok, result = xpcall(function()
    return Compiler.compile(source)
  end, debug.traceback)
  restore()
  if not ok then
    error(result, 0)
  end

  local widget = result.manifest.widgets.ball_open
  Assert.equal(widget.width, 24)
  Assert.equal(widget.height, 24)
  Assert.deepEqual(widget.anchor, { x = 8, y = 8 })
  Assert.equal(#widget.frames, 2)
  Assert.equal(widget.frames[1].width, widget.width)
  Assert.equal(widget.frames[2].height, widget.height)
  Assert.equal(widget.frames[1].duration, 2)
  Assert.equal(widget.frames[2].duration, 3)
end

function T.shrink_source_configuration_starts_after_the_displayed_full_portrait()
  local config = require("romdump.src.config.IntroAssets")
  Assert.deepEqual(config.shrink.male.chars, { 22, 23, 24, 25 })
  Assert.deepEqual(config.shrink.female.chars, { 26, 27, 28, 29 })
end

local function introCache()
  local ok, cache = pcall(require, "libs.assets.src.IntroAssetCache")
  if not ok then
    error("the intro visual cache contract is missing: " .. tostring(cache), 0)
  end
  return cache
end

local function writer()
  local ok, module = pcall(require, "romdump.src.digest.IntroAssetCacheWriter")
  if not ok then
    error("the intro cache has no failure-safe publication path: " .. tostring(module), 0)
  end
  return module
end

local function fixtureBundle(cache, marker)
  local assets, widgets = {}, {}
  assets[cache.assetDir() .. "/background.png"] = "png"
  for _, id in ipairs(cache.REQUIRED_ASSETS) do
    local image = cache.assetDir() .. "/" .. id .. ".png"
    widgets[id] = {
      image = image,
      width = 1,
      height = 1,
      anchor = { x = 0, y = 0 },
      sourceBounds = { x = 0, y = 0, width = 1, height = 1 },
      sampling = "nearest",
      provenance = { rule = "fixture" },
      frames = { { image = image, width = 1, height = 1, duration = 1, anchor = { x = 0, y = 0 } } },
    }
    if id == "gender_male" then
      widgets[id].sourceCenter = { x = 64, y = 104 }
    elseif id == "gender_female" then
      widgets[id].sourceCenter = { x = 192, y = 104 }
    elseif id == "ball_open" or id == "marill_appear" or id == "marill" then
      widgets[id].sourceCenter = { x = 128, y = 90 }
    end
    assets[image] = "png"
  end
  return {
    marker = marker,
    manifest = {
      schemaVersion = 3,
      variant = "heartgold",
      sourceReference = { width = 256, height = 192 },
      background = {
        image = cache.assetDir() .. "/background.png",
        width = 1,
        height = 192,
        sampling = "linear",
        provenance = { fixture = true },
      },
      widgets = widgets,
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
