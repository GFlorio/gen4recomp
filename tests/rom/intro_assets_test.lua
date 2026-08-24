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
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    for field, memberId in pairs({ char = 64, palette = 63, cell = 65, animation = 66 }) do
      Assert.equal(sourceMember(bundle, id .. ":" .. field), memberId, id .. " uses resource-set-5 " .. field)
      Assert.equal(sourceArchive(bundle, id .. ":" .. field), "intro")
    end
  end
  for _, id in ipairs({ "ball_open", "marill_appear", "marill" }) do
    for role, memberId in pairs({
      ["resdat-header"] = 78,
      ["resdat-char-table"] = 26,
      ["resdat-palette-table"] = 27,
      ["resdat-cell-table"] = 25,
      ["resdat-animation-table"] = 24,
    }) do
      Assert.equal(sourceMember(bundle, id .. ":" .. role), memberId, id .. " uses shared resdat mapping")
      Assert.equal(sourceArchive(bundle, id .. ":" .. role), "NARC_data_resdat")
    end
  end
end

local function assertVariant(bundle, versionId, paletteMember)
  Assert.equal(bundle.manifest.schemaVersion, 3)
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

local function assertGenderSource(bundle, paletteMember)
  for _, id in ipairs({ "gender_male", "gender_female" }) do
    Assert.notNil(bundle.manifest.widgets[id], id .. " semantic selector is present")
    Assert.isTrue(#bundle.manifest.widgets[id].frames > 0, id .. " has visible frames")
    Assert.notNil(bundle.assets[bundle.manifest.widgets[id].frames[1].image], id .. " has image output")
  end
  Assert.notNil(bundle.manifest.widgets.gender_background, "gender auxiliary background is present")
  Assert.notNil(bundle.assets[bundle.manifest.widgets.gender_background.image], "gender background has image output")
  Assert.equal(sourceMember(bundle, "gender-background:char"), 32)
  Assert.equal(sourceMember(bundle, "gender-background:screen"), 51)
  Assert.equal(sourceMember(bundle, "gender-background:palette"), paletteMember)
  Assert.equal(sourceMember(bundle, "gender-male:resource-set"), 1)
  Assert.equal(sourceMember(bundle, "gender-female:resource-set"), 2)
  Assert.notNil(bundle.manifest.widgets.male, "main male portrait remains distinct")
  Assert.notNil(bundle.manifest.widgets.female, "main female portrait remains distinct")
end

function T.both_variants_compile_the_correct_gradient(romFs, versionId)
  local first = assert(compiler().compile(romFs))
  local second = assert(compiler().compile(romFs))
  assertVariant(first, versionId, versionId == "heartgold" and 1 or 2)
  assertGenderSource(first, versionId == "heartgold" and 30 or 31)
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
  Assert.keySet(
    bundle.manifest.widgets,
    "ball_open,female,gender_background,gender_female,gender_male,male,marill,marill_appear,oak,shrink_female,shrink_male"
  )
  for id, widget in pairs(bundle.manifest.widgets) do
    Assert.equal(widget.sampling, "nearest", id .. " uses nearest sampling")
    if id ~= "gender_background" then
      Assert.isTrue(widget.width < 256 or widget.height < 192, id .. " is not a full-screen visual")
    end
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
  Assert.equal(bundle.manifest.widgets.marill_appear.sourceCenter.x, 160)
  Assert.equal(bundle.manifest.widgets.marill.sourceCenter.x, 160)
  Assert.isNil(bundle.manifest.widgets.ball)
end

return RomSuite.fromFacts(T)
