-- ROM-conformance scenarios for the semantic Professor Oak intro asset class.
-- Source member identities are asserted only in producer provenance; runtime
-- records are checked through their semantic background/widget contract.

local Assert = require("tests.support.Assert")
local PngReader = require("tests.support.PngReader")
local RomSuite = require("tests.rom.support.RomSuite")

local T = {}

local function compiler()
  local ok, module = pcall(require, "romdump.src.digest.IntroAssetCompiler")
  if not ok then
    error("the ROM-derived intro compiler is missing: " .. tostring(module), 0)
  end
  return module
end

local function payloadBytes(bundle)
  local paths = {}
  for path in pairs(bundle.assets) do
    paths[#paths + 1] = path
  end
  table.sort(paths)
  local bytes = {}
  for _, path in ipairs(paths) do
    bytes[#bytes + 1] = path .. "\0" .. bundle.assets[path]
  end
  return table.concat(bytes, "\0")
end

local function sourceMember(bundle, role)
  for _, item in ipairs(bundle.dependencies.dependencies) do
    if item.role == role then
      return item.memberId
    end
  end
  error("missing dependency role " .. role, 2)
end

local function sourceArchive(bundle, role)
  for _, item in ipairs(bundle.dependencies.dependencies) do
    if item.role == role then
      return item.archive
    end
  end
  error("missing dependency role " .. role, 2)
end

local function assertBallSource(bundle)
  local expected = {
    ["ball_open:char"] = { archive = "intro", memberId = 64 },
    ["ball_open:palette"] = { archive = "intro", memberId = 63 },
    ["ball_open:cell"] = { archive = "intro", memberId = 65 },
    ["ball_open:animation"] = { archive = "intro", memberId = 66 },
    ["ball_open:resdat-header"] = { archive = "NARC_data_resdat", memberId = 78 },
    ["ball_open:resdat-char-table"] = { archive = "NARC_data_resdat", memberId = 26 },
    ["ball_open:resdat-palette-table"] = { archive = "NARC_data_resdat", memberId = 27 },
    ["ball_open:resdat-cell-table"] = { archive = "NARC_data_resdat", memberId = 25 },
    ["ball_open:resdat-animation-table"] = { archive = "NARC_data_resdat", memberId = 24 },
  }
  for role, source in pairs(expected) do
    Assert.equal(sourceMember(bundle, role), source.memberId, role .. " resolves the pinned source member")
    Assert.equal(sourceArchive(bundle, role), source.archive, role .. " uses the pinned source archive")
  end
  Assert.equal(sourceMember(bundle, "marill:char"), 60)
  Assert.equal(sourceMember(bundle, "marill:palette"), 59)
  Assert.equal(sourceMember(bundle, "marill:cell"), 61)
  Assert.equal(sourceMember(bundle, "marill:animation"), 62)
end

local function assertVariant(bundle, versionId, paletteMember)
  Assert.equal(bundle.manifest.schemaVersion, 2)
  Assert.equal(bundle.manifest.variant, versionId)
  Assert.equal(sourceMember(bundle, "background:char"), 0)
  Assert.equal(sourceMember(bundle, "background:screen"), 3)
  Assert.equal(sourceMember(bundle, "background:palette"), paletteMember)
  Assert.equal(bundle.manifest.background.width, 1)
  Assert.equal(bundle.manifest.background.height, 192)
  Assert.equal(bundle.manifest.background.sampling, "linear")

  local _, height, rgba = PngReader.rgba(bundle.assets[bundle.manifest.background.image])
  local colors = {}
  for row = 0, height - 1 do
    colors[rgba:sub(row * 4 + 1, row * 4 + 4)] = true
  end
  local distinct = 0
  for _ in pairs(colors) do
    distinct = distinct + 1
  end
  Assert.isTrue(distinct > 1, "the source-derived background gradient is not flat")
end

function T.both_variants_compile_the_correct_gradient(romFs, versionId)
  local first = assert(compiler().compile(romFs))
  local second = assert(compiler().compile(romFs))
  assertVariant(first, versionId, versionId == "heartgold" and 1 or 2)
  assertBallSource(first)
  Assert.equal(first.manifest.widgets.ball_open.sourceCenter.x, 160)
  Assert.equal(first.manifest.widgets.ball_open.sourceCenter.y, 80)
  Assert.isTrue(#first.manifest.widgets.ball_open.frames > 0, "ball_open has animation frames")
  Assert.deepEqual(first.manifest, second.manifest, "same source produces deterministic manifest")
  Assert.deepEqual(first.dependencies, second.dependencies, "same source produces deterministic provenance")
  Assert.equal(payloadBytes(first), payloadBytes(second), "same source produces deterministic image bytes")
end

function T.compiled_visuals_are_stable_semantic_widgets(romFs)
  local bundle = assert(compiler().compile(romFs))
  Assert.keySet(bundle.manifest.widgets, "ball_open,female,male,marill,oak,shrink_female,shrink_male")
  for id, widget in pairs(bundle.manifest.widgets) do
    Assert.equal(widget.sampling, "nearest", id .. " uses nearest sampling")
    Assert.isTrue(widget.width < 256 or widget.height < 192, id .. " is not a full-screen visual")
    Assert.isTrue(widget.anchor.x >= 0 and widget.anchor.x <= widget.width, id .. " anchor x is bounded")
    Assert.isTrue(widget.anchor.y >= 0 and widget.anchor.y <= widget.height, id .. " anchor y is bounded")
    Assert.isTrue(widget.sourceBounds.x + widget.sourceBounds.width <= 256, id .. " source bounds fit width")
    Assert.isTrue(widget.sourceBounds.y + widget.sourceBounds.height <= 192, id .. " source bounds fit height")
    Assert.isTrue(#widget.frames > 0, id .. " has visible frames")
    for frameIndex, frame in ipairs(widget.frames) do
      Assert.equal(frame.width, widget.width, id .. " frame " .. frameIndex .. " width is stable")
      Assert.equal(frame.height, widget.height, id .. " frame " .. frameIndex .. " height is stable")
      Assert.deepEqual(frame.anchor, widget.anchor, id .. " frame " .. frameIndex .. " anchor is stable")
      Assert.isTrue(frame.duration > 0, id .. " frame " .. frameIndex .. " has fixed timing")
      local _, decodedHeight = PngReader.rgba(bundle.assets[frame.image])
      Assert.equal(decodedHeight, frame.height, id .. " frame payload has declared height")
    end
  end
  Assert.equal(bundle.manifest.widgets.ball_open.sourceCenter.x, 160)
  Assert.equal(bundle.manifest.widgets.ball_open.sourceCenter.y, 80)
  Assert.isNil(bundle.manifest.widgets.ball)
end

return RomSuite.fromFacts(T)
