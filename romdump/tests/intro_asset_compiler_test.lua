-- Producer-side intro output contract: malformed source fails with source
-- context, the semantic class is minimal and deterministic, and publication
-- keeps an older ready class when staging or replacement fails.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local PngReader = require("tests.support.PngReader")

local T = {}

function T.reveal_source_configuration_uses_resource_set_five_sequences_and_palettes()
  local config = require("romdump.src.config.IntroAssets")
  for id, sequence, palette in pairs({ ball_open = { 3, 4 }, marill_appear = { 1, 4 }, marill = { 2, 4 } }) do
    local entry = assert(config[id])
    Assert.equal(entry.archive, "intro")
    Assert.isNil(entry.char)
    Assert.isNil(entry.palette)
    Assert.isNil(entry.cell)
    Assert.isNil(entry.animation)
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
    local expectedOverride = id == "female" and 1 or 0
    Assert.equal(entry.paletteOverride, expectedOverride)
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

local function syntheticCompilerSource(animationFrames)
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

  -- Intro cell-animation OBJs (male/female/ball/Marill) are 4bpp source
  -- sprites: depth 3, 32 bytes per 8x8 tile, two 4-bit pixel indices per
  -- byte. Both nibbles carry the same non-zero value so each tile stays
  -- opaque after alpha-union cropping.
  rawset(decoder, "decodeChar", function()
    local tiles = {}
    for tile = 0, 23 do
      local nibble = tile % 15 + 1
      tiles[#tiles + 1] = string.rep(string.char(nibble * 17), 32)
    end
    return { depth = 3, tiles = table.concat(tiles) }
  end)
  -- Six 16-color banks so every configured selector (male=0, female=1,
  -- ball/Marill=4) resolves within the decoded palette resource.
  rawset(decoder, "decodePalette", function()
    local colors = {}
    for index = 1, 96 do
      colors[index] = { r = index % 256, g = (index + 1) % 256, b = (index + 2) % 256 }
    end
    return { colors = colors }
  end)
  rawset(decoder, "decodeScreen", function()
    local entries = {}
    for row = 0, 23 do
      entries[#entries + 1] = { tile = row, palette = row == 0 and 3 or 0, flipH = false, flipV = false }
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
    local selected = {
      frames = animationFrames or { { cell = 0, duration = 2 }, { cell = 1, duration = 3 } },
    }
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

function T.gender_selector_neutral_surface_preserves_source_chrome_only()
  local Compiler = compiler()
  local source, restore = syntheticCompilerSource()
  local ok, result = xpcall(function()
    return Compiler.compile(source)
  end, debug.traceback)
  restore()
  if not ok then
    error(result, 0)
  end

  local neutral = assert(result.manifest.genderSelector.neutral)
  local width, height, rgba = PngReader.rgba(assert(result.assets[neutral.image]))
  Assert.equal(width, 8)
  Assert.equal(height, 192)
  local _, _, _, backgroundAlpha = PngReader.pixel(rgba, width, 0, 0)
  local _, _, _, chromeAlpha = PngReader.pixel(rgba, width, 0, 8)
  local _, _, _, dynamicAlpha = PngReader.pixel(rgba, width, 0, 88)
  Assert.equal(backgroundAlpha, 0, "selector background is transparent")
  Assert.equal(chromeAlpha, 255, "static selector chrome remains opaque")
  Assert.equal(dynamicAlpha, 0, "dynamic selector roles remain outside neutral chrome")
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

function T.transformed_animation_frames_share_one_generated_anchor()
  local Compiler = compiler()
  local source, restore = syntheticCompilerSource({
    { cell = 0, duration = 2, translateX = 0, translateY = 0 },
    { cell = 0, duration = 3, translateX = 8, translateY = 4 },
  })
  local ok, result = xpcall(function()
    return Compiler.compile(source)
  end, debug.traceback)
  restore()
  if not ok then
    error(result, 0)
  end

  local widget = result.manifest.widgets.ball_open
  Assert.deepEqual(widget.anchor, { x = 8, y = 8 })
  Assert.equal(widget.frames[1].width, widget.frames[2].width)
  Assert.equal(widget.frames[1].height, widget.frames[2].height)
  Assert.equal(widget.frames[1].translateX, 0)
  Assert.equal(widget.frames[2].translateX, 8)
  Assert.equal(widget.frames[1].translateY, 0)
  Assert.equal(widget.frames[2].translateY, 4)
  Assert.isTrue(result.assets[widget.frames[1].image] ~= result.assets[widget.frames[2].image])
end

function T.shrink_source_configuration_starts_after_the_displayed_full_portrait()
  local config = require("romdump.src.config.IntroAssets")
  Assert.deepEqual(config.shrink.male.chars, { 22, 23, 24, 25 })
  Assert.deepEqual(config.shrink.female.chars, { 26, 27, 28, 29 })
end

function T.shrink_assets_keep_source_order_and_use_nine_tick_replacements()
  local Compiler = compiler()
  local source, restore = syntheticCompilerSource()
  local ok, result = xpcall(function()
    return Compiler.compile(source)
  end, debug.traceback)
  restore()
  if not ok then
    error(result, 0)
  end

  for _, expected in ipairs({
    { id = "shrink_male", chars = { 22, 23, 24, 25 }, palette = 16 },
    { id = "shrink_female", chars = { 26, 27, 28, 29 }, palette = 21 },
  }) do
    local widget = assert(result.manifest.widgets[expected.id])
    Assert.equal(#widget.frames, 4)
    for _, frame in ipairs(widget.frames) do
      Assert.equal(frame.duration, 9)
    end
    Assert.equal(widget.provenance.rule, "portrait-screen-alpha-union")
    Assert.equal(widget.provenance.screenMember, 9)
    Assert.equal(widget.provenance.paletteMember, expected.palette)

    local members = {}
    for _, dependency in ipairs(result.dependencies.dependencies) do
      if dependency.role:match("^" .. expected.id .. ":char:") then
        members[#members + 1] = dependency.memberId
      end
    end
    Assert.deepEqual(members, expected.chars)
  end
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
    local framePlacement = { element = "none", translateX = 0, translateY = 0, scaleX = 1, scaleY = 1, rotation = 0 }
    widgets[id] = {
      image = image,
      width = 1,
      height = 1,
      anchor = { x = 0, y = 0 },
      sourceBounds = { x = 0, y = 0, width = 1, height = 1 },
      sampling = "nearest",
      provenance = { rule = "fixture" },
      frames = {
        {
          image = image,
          width = 1,
          height = 1,
          duration = 1,
          anchor = { x = 0, y = 0 },
          element = framePlacement.element,
          translateX = framePlacement.translateX,
          translateY = framePlacement.translateY,
          scaleX = framePlacement.scaleX,
          scaleY = framePlacement.scaleY,
          rotation = framePlacement.rotation,
        },
      },
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
  local genderSelector = { neutral = {}, buttons = { male = {}, female = {} } }
  local neutralImage = cache.assetDir() .. "/gender-selector-neutral.png"
  genderSelector.neutral = { image = neutralImage, width = 256, height = 192 }
  genderSelector.defaultTone = { r = 200, g = 200, b = 200 }
  assets[neutralImage] = "png"
  for _, gender in ipairs({ "male", "female" }) do
    for _, kind in ipairs({ "pulseMask", "accentMask" }) do
      local maskImage = cache.assetDir() .. "/gender-selector-" .. gender .. "-" .. kind .. ".png"
      genderSelector.buttons[gender][kind] = {
        image = maskImage,
        width = 4,
        height = 4,
        bounds = { x = 0, y = 0, width = 4, height = 4 },
      }
      assets[maskImage] = "png"
    end
    genderSelector.buttons[gender].bounds = { x = 0, y = 0, width = 4, height = 4 }
  end
  return {
    marker = marker,
    manifest = {
      schemaVersion = 5,
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
      genderSelector = genderSelector,
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
