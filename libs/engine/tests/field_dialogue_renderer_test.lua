-- LÖVE smoke tests for the dialogue renderer (spec sections 15.3-15.6 and
-- 21.7): synthetic font def + atlas load, box geometry at every host aspect,
-- and graphics-state restoration after a draw. These run only under love with
-- a graphics context (the aggregate suite skips them headless).

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.rom.src.CacheFs")
local Errors = require("libs.rom.src.Errors")
local FakeCache = require("tests.support.FakeCache")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

local function hasGraphics()
  return love and love.graphics and love.graphics.newImage and love.image
end

local function px(r, g, b, a)
  return string.char(r, g, b, a)
end

-- 16x16 atlas: two 8x16 glyph cells (red 'A', green 'B') plus a fallback.
local function atlasBytes()
  local rgba = {}
  for y = 1, 16 do
    for x = 1, 16 do
      local color = x <= 8 and px(200, 40, 40, 255) or px(40, 200, 40, 255)
      rgba[#rgba + 1] = color
    end
  end
  return PngWriter.encode(16, 16, table.concat(rgba))
end

local function fontDef()
  return {
    schema = "g4-field-font-v1",
    fontId = 0,
    lineHeight = 16,
    maxLetterHeight = 16,
    letterSpacing = 0,
    atlas = { width = 16, height = 16, glyphsPerRow = 2, glyphWidth = 8, glyphHeight = 16 },
    glyphs = {
      [1] = { x = 0, y = 0, w = 8, h = 16, advance = 6, bearingX = 0, bearingY = 0 },
      [2] = { x = 8, y = 0, w = 8, h = 16, advance = 6, bearingX = 0, bearingY = 0 },
      [0] = { x = 0, y = 0, w = 8, h = 16, advance = 4, bearingX = 0, bearingY = 0 },
    },
    charmap = { A = 1, B = 2, [" "] = 0 },
  }
end

local function cacheWithFont()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write("data/generated/field/font/font-0.lua", require("libs.rom.src.LuaWriter").encode(fontDef()))
  cache:write("assets/generated/field/font/font-0.png", atlasBytes())
  return cache
end

local function openDialogue(renderer, text)
  local tokens = {
    { kind = "glyph", code = 1, text = "A", raw = { 1 } },
    { kind = "glyph", code = 2, text = "B", raw = { 2 } },
  }
  local controller = FieldDialogueController.new({
    layout = function()
      return {
        pages = {
          { lines = { { tokens = tokens, width = 12 } }, breakKind = "eos" },
        },
        warnings = {},
      }
    end,
  })
  controller:open({
    id = "smoke",
    message = { bankId = 543, messageId = 5, text = text, tokens = tokens, hadUnresolvedSubstitutions = false },
    style = "default",
    modal = true,
    allowCancel = false,
  })
  return controller
end

function T.loads_def_and_atlas()
  if not hasGraphics() then
    return
  end
  local renderer = FieldDialogueRenderer.new({ cacheFs = cacheWithFont() })
  Assert.equal(renderer.fontDef.schema, "g4-field-font-v1")
  Assert.notNil(renderer.atlas)
  Assert.equal(renderer.atlas:getWidth(), 16)
  renderer:release()
end

function T.missing_def_is_a_typed_error()
  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = CacheFs.forVersion("heartgold", FakeCache.new()) })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "FONT_DEF_MISSING", "raises FONT_DEF_MISSING")
end

function T.does_not_require_graphics_headless()
  local renderer = FieldDialogueRenderer.new({
    cacheFs = cacheWithFont(),
    graphics = nil,
  })
  Assert.notNil(renderer.fontDef)
  Assert.isNil(renderer.atlas)
  renderer:release()
end

function T.restores_graphics_state_after_draw()
  if not hasGraphics() then
    return
  end
  local lg = love.graphics
  local renderer = FieldDialogueRenderer.new({ cacheFs = cacheWithFont() })
  local controller = openDialogue(renderer, "AB")
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })

  local canvas = lg.newCanvas(64, 64)
  lg.setCanvas(canvas)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  renderer:draw(controller, viewport)

  Assert.equal(lg.getCanvas(), canvas)
  local blend, alpha = lg.getBlendMode()
  Assert.equal(blend, "add")
  Assert.equal(alpha, "alphamultiply")
  local depthMode, depthWrite = lg.getDepthMode()
  Assert.equal(depthMode, "lequal")
  Assert.equal(depthWrite, true)
  Assert.equal(lg.isWireframe(), true)
  Assert.equal(lg.getMeshCullMode(), "back")
  local r, g, b, a = lg.getColor()
  Assert.equal(r, 0.2)
  Assert.equal(g, 0.4)
  Assert.equal(b, 0.6)
  Assert.equal(a, 0.8)
  local sx, sy, sw, sh = lg.getScissor()
  Assert.equal(sx, 4)
  Assert.equal(sy, 8)
  Assert.equal(sw, 32)
  Assert.equal(sh, 16)

  lg.setCanvas()
  renderer:release()
end

function T.closed_controller_draws_nothing_without_state_changes()
  if not hasGraphics() then
    return
  end
  local lg = love.graphics
  local renderer = FieldDialogueRenderer.new({ cacheFs = cacheWithFont() })
  local controller = FieldDialogueController.new({
    layout = function()
      return { pages = {}, warnings = {} }
    end,
  })
  local viewport = FieldViewport.new(960, 720, { mode = "expanded" })
  lg.setColor(0.1, 0.2, 0.3, 0.4)
  renderer:draw(controller, viewport)
  local r = lg.getColor()
  Assert.equal(r, 0.1)
  Assert.isNil(lg.getShader())
  renderer:release()
end

function T.draw_works_at_every_host_aspect()
  if not hasGraphics() then
    return
  end
  local renderer = FieldDialogueRenderer.new({ cacheFs = cacheWithFont() })
  for _, size in ipairs({ { 960, 720 }, { 1280, 720 }, { 1920, 720 }, { 640, 480 } }) do
    local controller = openDialogue(renderer, "AB")
    local viewport = FieldViewport.new(size[1], size[2], { mode = "expanded" })
    renderer:draw(controller, viewport)
    local layout = FieldDialogueTheme.layout(viewport.referenceFrame)
    local box = FieldDialogueTheme.screenRect(layout, layout.box)
    Assert.isTrue(box.x >= viewport.referenceFrame.x, "box inside frame at " .. size[1] .. "x" .. size[2])
    Assert.isTrue(box.x + box.width <= viewport.referenceFrame.x + viewport.referenceFrame.width + 1e-9)
    Assert.isTrue(
      box.y >= viewport.referenceFrame.y
        and box.y + box.height <= viewport.referenceFrame.y + viewport.referenceFrame.height + 1e-9
    )
  end
  renderer:release()
end

function T.nine_slice_draws_border_and_fill_at_correct_pixels()
  if not hasGraphics() then
    return
  end
  local lg = love.graphics
  local renderer = FieldDialogueRenderer.new({ cacheFs = cacheWithFont() })
  local controller = openDialogue(renderer, "AB")
  local viewport = FieldViewport.new(960, 720, { mode = "expanded" })
  local canvas = lg.newCanvas(960, 720)
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  renderer:draw(controller, viewport)
  lg.setCanvas()
  local data = canvas:newImageData()
  canvas:release()

  local layout = FieldDialogueTheme.layout(viewport.referenceFrame)
  local box = FieldDialogueTheme.screenRect(layout, layout.box)
  -- Top border slice (2 reference px tall -> 7.5 screen px).
  local br, bg, bb, ba = data:getPixel(math.floor(box.x + box.width / 2), math.floor(box.y + 3))
  Assert.near(br, 0.16, 0.05, "top border red")
  Assert.near(bg, 0.20, 0.05, "top border green")
  Assert.near(bb, 0.42, 0.05, "top border blue")
  -- Left border slice, vertically centered (clear of the text lines).
  local lr, lgg, lb = data:getPixel(math.floor(box.x + 3), math.floor(box.y + box.height / 2))
  Assert.near(lr, 0.16, 0.05, "left border red")
  Assert.near(lgg, 0.20, 0.05, "left border green")
  Assert.near(lb, 0.42, 0.05, "left border blue")
  -- Center fill below the text lines: the light window color alpha-blended
  -- over the cleared canvas (0.93 * 0.96).
  local fr, fg, fb = data:getPixel(math.floor(box.x + box.width / 2), math.floor(box.y + box.height - 12))
  Assert.near(fr, 0.89, 0.05, "fill red")
  Assert.near(fg, 0.89, 0.05, "fill green")
  Assert.near(fb, 0.93, 0.05, "fill blue")
end

function T.release_frees_owned_images()
  if not hasGraphics() then
    return
  end
  local renderer = FieldDialogueRenderer.new({ cacheFs = cacheWithFont() })
  renderer:release()
  Assert.isNil(renderer.atlas)
  Assert.isNil(renderer._sliceImage)
end

return T
