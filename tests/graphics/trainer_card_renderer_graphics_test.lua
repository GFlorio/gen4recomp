-- Graphics smoke tests for the Trainer Card renderer: the canonical 256x192
-- front viewer renders pixel-exact against an independently composed
-- reference (the fixture card art with the audited label/value glyphs at the
-- source anchors, and the real generated assets from the shared derived
-- cache when a UI class is present), every graphics state the draw touched
-- is proven restored against the real driver, and release frees the owned
-- images. The construction/draw failure paths are injected fakes and stay in
-- trainer_card_renderer_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldUiAssetCache = require("libs.assets.src.FieldUiAssetCache")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local TrainerCardRenderer = require("libs.engine.src.TrainerCardRenderer")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

local function canonicalViewport()
  return FieldViewport.new(CANONICAL_WIDTH, CANONICAL_HEIGHT, { mode = "expanded" })
end

-- The demo §29.1 presentation.
local function demoPresentation()
  return {
    open = true,
    name = "GOLD",
    gender = 0,
    trainerId = 0,
    money = nil,
    playTime = nil,
    badges = nil,
    pokedexOwned = nil,
    stars = nil,
    signature = nil,
  }
end

-- Renders one canonical card presentation into a real canvas and returns its
-- ImageData.
---@param scope GraphicsScope
---@param cacheFs CacheFs
---@param presentation table
---@return love.ImageData
local function canonicalRender(scope, cacheFs, presentation)
  local lg = love.graphics
  local renderer = scope:own(TrainerCardRenderer.new({ cacheFs = cacheFs }))
  local canvas = scope:own(lg.newCanvas(CANONICAL_WIDTH, CANONICAL_HEIGHT))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  renderer:draw(presentation, canonicalViewport())
  lg.setCanvas()
  return scope:own(canvas:newImageData())
end

-- Compares two ImageData buffers 8-bit channel by 8-bit channel; a single
-- differing pixel fails with its canonical coordinates.
local function assertPixelsEqual(expected, actual, label)
  Assert.equal(expected:getWidth(), actual:getWidth(), label .. " width")
  Assert.equal(expected:getHeight(), actual:getHeight(), label .. " height")
  local function quantize(v)
    return math.floor(v * 255 + 0.5)
  end
  for y = 0, CANONICAL_HEIGHT - 1 do
    for x = 0, CANONICAL_WIDTH - 1 do
      local er, eg, eb, ea = expected:getPixel(x, y)
      local ar, ag, ab, aa = actual:getPixel(x, y)
      if
        quantize(er) ~= quantize(ar)
        or quantize(eg) ~= quantize(ag)
        or quantize(eb) ~= quantize(ab)
        or quantize(ea) ~= quantize(aa)
      then
        error(
          string.format(
            "%s: pixel mismatch at (%d,%d): expected (%d,%d,%d,%d) got (%d,%d,%d,%d)",
            label,
            x,
            y,
            quantize(er),
            quantize(eg),
            quantize(eb),
            quantize(ea),
            quantize(ar),
            quantize(ag),
            quantize(ab),
            quantize(aa)
          )
        )
      end
    end
  end
end

-- Pastes one text string's glyph pixels into the reference at the given
-- origin using the fixture font def and the per-code solid glyph colors.
---@param reference love.ImageData
---@param fontDef table
---@param text string
---@param originX number
---@param originY number
local function pasteText(reference, fontDef, text, originX, originY)
  local x = originX
  for i = 1, #text do
    local char = text:sub(i, i)
    local code = fontDef.charmap[char] or 0
    local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
    local r, g, b = FieldUiFixture.cardGlyphColor(code)
    for y = 0, glyph.h - 1 do
      for gx = 0, glyph.w - 1 do
        reference:setPixel(x + gx, originY + y, r / 255, g / 255, b / 255, 1)
      end
    end
    x = x + glyph.advance
  end
  return x
end

-- The independent fixture reference: the card art pixels plus the audited
-- labels and the two authoritative values at the source anchors. Built
-- without the renderer, so a draw regression (wrong rect, wrong anchor,
-- wrong alignment, wrong glyph) is a mismatch.
---@param presentation table
---@return love.ImageData
local function fixtureReference(presentation)
  local reference = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  local art =
    love.image.newImageData(love.filesystem.newFileData(FieldUiFixture.cardBytes(), FieldUiFixture.TRAINER_CARD_PATH))
  local function blend(target, source, originX, originY)
    for y = 0, source:getHeight() - 1 do
      for x = 0, source:getWidth() - 1 do
        local r, g, b, a = source:getPixel(x, y)
        if a > 0 then
          target:setPixel(originX + x, originY + y, r, g, b, a)
        end
      end
    end
  end
  blend(reference, art, 0, 0)
  local fontDef = FieldUiFixture.cardFontDef()
  local function measure(text)
    local width = 0
    for i = 1, #text do
      local code = fontDef.charmap[text:sub(i, i)] or 0
      local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
      width = width + glyph.advance
    end
    return width
  end
  for _, anchor in ipairs(TrainerCardRenderer.LABEL_ANCHORS) do
    pasteText(reference, fontDef, anchor.text, anchor.x, anchor.y)
  end
  pasteText(reference, fontDef, presentation.name, TrainerCardRenderer.NAME_RIGHT_EDGE - measure(presentation.name), 24)
  local trainerId = string.format("%05d", presentation.trainerId)
  pasteText(reference, fontDef, trainerId, TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE - measure(trainerId), 24)
  return reference
end

-- Canonical golden: the fixture card front with the demo profile matches the
-- independent reference pixel for pixel.
function T.canonical_golden_matches_the_fixture_card_pixel_for_pixel(scope)
  local presentation = demoPresentation()
  local rendered = canonicalRender(scope, FieldUiFixture.trainerCardCache(), presentation)
  assertPixelsEqual(fixtureReference(presentation), rendered, "fixture trainer card golden")
end

-- The profile values are authoritative text placement: a boundary name and
-- trainer id render at their right-aligned anchors with the zero-padded id.
function T.profile_values_render_at_the_audited_anchors(scope)
  local presentation = demoPresentation()
  presentation.name = "ABCDEFG"
  presentation.trainerId = 65535
  local rendered = canonicalRender(scope, FieldUiFixture.trainerCardCache(), presentation)
  assertPixelsEqual(fixtureReference(presentation), rendered, "boundary profile golden")
end

-- The optional fields stay blank: a reference that fabricates a money value
-- must differ from the rendered card (the blank presentation is the
-- contract, never invented statistics).
function T.nil_optional_fields_never_fabricate_values(scope)
  local presentation = demoPresentation()
  local rendered = canonicalRender(scope, FieldUiFixture.trainerCardCache(), presentation)
  local fabricated = fixtureReference(presentation)
  -- Fabricate a money value glyph run at the money row (16,48) + the label
  -- width: the reference must then differ from the render.
  local fontDef = FieldUiFixture.cardFontDef()
  pasteText(fabricated, fontDef, "123", 16 + 5 * 8, 48)
  local quantize = function(v)
    return math.floor(v * 255 + 0.5)
  end
  local differs = false
  for y = 48, 63 do
    for x = 56, 79 do
      local er, eg, eb, ea = fabricated:getPixel(x, y)
      local ar, ag, ab, aa = rendered:getPixel(x, y)
      if
        quantize(er) ~= quantize(ar)
        or quantize(eg) ~= quantize(ag)
        or quantize(eb) ~= quantize(ab)
        or quantize(ea) ~= quantize(aa)
      then
        differs = true
      end
    end
  end
  Assert.isTrue(differs, "the render must stay blank where a fabricated value would appear")
end

-- The reserved signature region stays art-only: every pixel of the bottom
-- band matches the art reference (no text, no editor surface).
function T.the_signature_region_stays_reserved(scope)
  local presentation = demoPresentation()
  local rendered = canonicalRender(scope, FieldUiFixture.trainerCardCache(), presentation)
  local art =
    love.image.newImageData(love.filesystem.newFileData(FieldUiFixture.cardBytes(), FieldUiFixture.TRAINER_CARD_PATH))
  local region = TrainerCardRenderer.SIGNATURE_REGION
  local quantize = function(v)
    return math.floor(v * 255 + 0.5)
  end
  for y = region.y, region.y + region.height - 1 do
    for x = region.x, region.x + region.width - 1 do
      if y < CANONICAL_HEIGHT then
        local er, eg, eb, ea = art:getPixel(x, y)
        local ar, ag, ab, aa = rendered:getPixel(x, y)
        Assert.equal(quantize(ar), quantize(er), "signature region red at (" .. x .. "," .. y .. ")")
        Assert.equal(quantize(ag), quantize(eg), "signature region green at (" .. x .. "," .. y .. ")")
        Assert.equal(quantize(ab), quantize(eb), "signature region blue at (" .. x .. "," .. y .. ")")
        Assert.equal(quantize(aa), quantize(ea), "signature region alpha at (" .. x .. "," .. y .. ")")
      end
    end
  end
end

-- Canonical golden: the real generated Trainer Card assets render pixel-exact
-- against an independent reference decoded from the same compiled PNG and the
-- real font definition (the card art is baked at compile time; the renderer's
-- job is placement and composition). Skips explicitly when no UI class is
-- present in the shared derived cache.
function T.canonical_golden_matches_the_real_generated_card_pixel_for_pixel(scope, context)
  local cache = CacheFs.forVersion("heartgold")
  if cache:getInfo(FieldUiAssetCache.manifestPath()) == nil then
    context:skip("no field-UI class in the shared derived cache")
    return
  end
  local manifest = assert(cache:loadLua(FieldUiAssetCache.manifestPath()), "the manifest must load")
  local front = manifest.assets["hgss.trainer_card.front"]
  Assert.notNil(front, "the generated class indexes the trainer card front")
  local trainerCard = assert(manifest.trainerCard, "the generated class carries the trainer card section")
  local fontDef = assert(cache:loadLua("data/generated/field/font/font-0.lua"), "the real font def must load")
  Assert.equal(fontDef.schema, "g4-field-font-v1", "the real font def schema")

  local reference = love.image.newImageData(CANONICAL_WIDTH, CANONICAL_HEIGHT)
  local art = love.image.newImageData(love.filesystem.newFileData(cache:read(front.image), front.image))
  local function blend(target, source, originX, originY)
    for y = 0, source:getHeight() - 1 do
      for x = 0, source:getWidth() - 1 do
        local r, g, b, a = source:getPixel(x, y)
        if a > 0 then
          target:setPixel(originX + x, originY + y, r, g, b, a)
        end
      end
    end
  end
  blend(reference, art, trainerCard.front.x, trainerCard.front.y)

  -- The audited text anchors, composed against the real font's advances.
  local function measureText(text)
    local width = 0
    for i = 1, #text do
      local code = fontDef.charmap[text:sub(i, i)]
      local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
      width = width + glyph.advance + (fontDef.letterSpacing or 0)
    end
    return width
  end
  local function pasteRealText(text, originX, originY)
    local x = originX
    for i = 1, #text do
      local char = text:sub(i, i)
      local code = fontDef.charmap[char]
      local glyph = fontDef.glyphs[code] or fontDef.glyphs[0]
      local glyphData = love.image.newImageData(
        love.filesystem.newFileData(cache:read("assets/generated/field/font/font-0.png"), "font-0.png")
      )
      local width, height = glyph.w, glyph.h
      local tile = love.image.newImageData(width, height)
      tile:paste(glyphData, 0, 0, glyph.x, glyph.y, width, height)
      for y = 0, height - 1 do
        for gx = 0, width - 1 do
          local r, g, b, a = tile:getPixel(gx, y)
          if a > 0 then
            reference:setPixel(x + gx, originY + y, r, g, b, a)
          end
        end
      end
      x = x + glyph.advance + (fontDef.letterSpacing or 0)
    end
    return x
  end
  for _, anchor in ipairs(TrainerCardRenderer.LABEL_ANCHORS) do
    pasteRealText(anchor.text, anchor.x, anchor.y)
  end
  local name = "GOLD"
  pasteRealText(name, TrainerCardRenderer.NAME_RIGHT_EDGE - measureText(name), 24)
  local trainerId = string.format("%05d", 0)
  pasteRealText(trainerId, TrainerCardRenderer.TRAINER_ID_RIGHT_EDGE - measureText(trainerId), 24)

  local rendered = canonicalRender(scope, cache, demoPresentation())
  assertPixelsEqual(reference, rendered, "real generated trainer card golden")
end

function T.restores_graphics_state_after_draw(scope)
  local lg = love.graphics
  local renderer = scope:own(TrainerCardRenderer.new({ cacheFs = FieldUiFixture.trainerCardCache() }))

  local canvas = scope:own(lg.newCanvas(64, 64))
  local shader = lg.getShader()
  lg.setCanvas(canvas)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  renderer:draw(demoPresentation(), FieldViewport.new(1280, 720, { mode = "expanded" }))

  local function assertRestored(canvasExpected, shaderExpected)
    Assert.equal(lg.getCanvas(), canvasExpected)
    Assert.equal(lg.getShader(), shaderExpected)
    local blend, alpha = lg.getBlendMode()
    Assert.equal(blend, "add")
    Assert.equal(alpha, "alphamultiply")
    local depthMode, depthWrite = lg.getDepthMode()
    Assert.equal(depthMode, "lequal")
    Assert.equal(depthWrite, true)
    Assert.equal(lg.isWireframe(), true)
    Assert.equal(lg.getMeshCullMode(), "back")
    local r, g, b, a = lg.getColor()
    Assert.near(r, 0.2, 1e-6)
    Assert.near(g, 0.4, 1e-6)
    Assert.near(b, 0.6, 1e-6)
    Assert.near(a, 0.8, 1e-6)
    local sx, sy, sw, sh = lg.getScissor()
    Assert.equal(sx, 4)
    Assert.equal(sy, 8)
    Assert.equal(sw, 32)
    Assert.equal(sh, 16)
  end
  assertRestored(canvas, shader)
end

-- Release is the contract here; it is still scoped so a failed assertion does
-- not leak the renderer. The scope's later release exercises repeat safety.
function T.release_frees_the_owned_images(scope)
  local renderer = scope:own(TrainerCardRenderer.new({ cacheFs = FieldUiFixture.trainerCardCache() }))

  renderer:release()

  Assert.isNil(renderer._atlas)
  Assert.isNil(renderer._cardImage)
end

return GraphicsSmoke.suite(T)
