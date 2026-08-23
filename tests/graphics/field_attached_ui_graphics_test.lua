-- Graphics smoke for field-attached dialogue/signpost: proves the single
-- translate+scale transform matches the bottom-centered layout.

local Assert = require("tests.support.Assert")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldSignpostRenderer = require("libs.engine.src.FieldSignpostRenderer")
local FieldSignpostFixture = require("tests.support.FieldSignpostFixture")
local FieldTextRenderer = require("libs.engine.src.FieldTextRenderer")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

local function fakeGraphicsFromSupport()
  return require("tests.support.FakeGraphics").new({
    imageSizes = {
      { 16, 16 },
      { 16, 16 },
      { 96, 32 },
      { 144, 16 },
      { 144, 8 },
      { 192, 32 },
    },
  })
end

function T.dialogue_uses_bottom_centered_translate_and_single_scale(scope)
  local lg = fakeGraphicsFromSupport()
  local text = FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames(), graphics = lg })
  local manifest = FieldUiFixture.manifest()
  local renderer = FieldDialogueRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest,
    text = text,
    graphics = lg,
  })
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local viewport = FieldViewport.new(768, 576, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local ref = viewport.referenceFrame
  local expectedScale = fieldScale
  local expectedX = ref.x + (ref.width - 256 * expectedScale) / 2
  local expectedY = ref.y + ref.height - 192 * expectedScale
  renderer:draw(controller, FieldDialogueTheme.layout(viewport.referenceFrame, fieldScale))
  Assert.equal(#lg.transforms, 2, "exactly one translate and one scale")
  Assert.equal(lg.transforms[1][1], "translate")
  Assert.near(lg.transforms[1][2], expectedX, 1e-6)
  Assert.near(lg.transforms[1][3], expectedY, 1e-6)
  Assert.equal(lg.transforms[2][1], "scale")
  Assert.near(lg.transforms[2][2], expectedScale, 1e-6)
  Assert.near(lg.transforms[2][3], expectedScale, 1e-6)
  renderer:release()
  text:release()
end

function T.dialogue_shrinks_from_bottom_center_at_reduced_zoom(scope)
  local lg = fakeGraphicsFromSupport()
  local text = FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames(), graphics = lg })
  local manifest = FieldUiFixture.manifest()
  local renderer = FieldDialogueRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest,
    text = text,
    graphics = lg,
  })
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local viewport = FieldViewport.new(768, 576, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(0.5)
  local ref = viewport.referenceFrame
  local expectedX = ref.x + (ref.width - 256 * fieldScale) / 2
  local expectedY = ref.y + ref.height - 192 * fieldScale
  renderer:draw(controller, FieldDialogueTheme.layout(viewport.referenceFrame, fieldScale))
  -- Current layout ignores zoom: will be at scale 3, origin 0,0 not expected 1.5 / bottom-centered.
  Assert.equal(#lg.transforms, 2, "exactly one translate and one scale")
  Assert.near(lg.transforms[1][2], expectedX, 1e-6, "bottom-centered X at 0.5x")
  Assert.near(lg.transforms[1][3], expectedY, 1e-6, "bottom-anchored Y at 0.5x")
  Assert.near(lg.transforms[2][2], fieldScale, 1e-6, "scale follows zoom at 0.5x")
  renderer:release()
  text:release()
end

function T.signpost_uses_same_bottom_centered_transform(scope)
  local lg = fakeGraphicsFromSupport()
  local text = FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames(), graphics = lg })
  local manifest = FieldUiFixture.manifest()
  local renderer = FieldSignpostRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest,
    text = text,
    graphics = lg,
    windowStyles = FieldSignpostFixture.styles(),
  })
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 })
  local viewport = FieldViewport.new(768, 576, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(1)
  local ref = viewport.referenceFrame
  local expectedX = ref.x + (ref.width - 256 * fieldScale) / 2
  local expectedY = ref.y + ref.height - 192 * fieldScale
  renderer:draw(controller, viewport, 1, fieldScale)
  Assert.equal(#lg.transforms, 2)
  Assert.near(lg.transforms[1][2], expectedX, 1e-6)
  Assert.near(lg.transforms[1][3], expectedY, 1e-6)
  Assert.near(lg.transforms[2][2], fieldScale, 1e-6)
  renderer:release()
  text:release()
end

function T.signpost_shrinks_from_bottom_center_at_reduced_zoom(scope)
  local lg = fakeGraphicsFromSupport()
  local text = FieldTextRenderer.new({ cacheFs = FieldUiFixture.cacheWithFontAndFrames(), graphics = lg })
  local manifest = FieldUiFixture.manifest()
  local renderer = FieldSignpostRenderer.new({
    cacheFs = FieldUiFixture.cacheWithFontAndFrames(),
    manifest = manifest,
    text = text,
    graphics = lg,
    windowStyles = FieldSignpostFixture.styles(),
  })
  local controller = FieldSignpostFixture.shown(FieldSignpostFixture.textLines(), { type = 2, offset = 0 })
  local viewport = FieldViewport.new(768, 576, { mode = "expanded" })
  local fieldScale = viewport:logicalPixelScale(0.5)
  local ref = viewport.referenceFrame
  local expectedX = ref.x + (ref.width - 256 * fieldScale) / 2
  local expectedY = ref.y + ref.height - 192 * fieldScale
  renderer:draw(controller, viewport, 1, fieldScale)
  Assert.near(lg.transforms[1][2], expectedX, 1e-6)
  Assert.near(lg.transforms[1][3], expectedY, 1e-6)
  Assert.near(lg.transforms[2][2], fieldScale, 1e-6)
  renderer:release()
  text:release()
end

return GraphicsSmoke.suite(T)
