-- Graphics smoke tests for the dialogue renderer: the synthetic font atlas is
-- decoded into a real Image, the box is drawn at every host aspect, the
-- nine-slice is read back from a canvas pixel by pixel, and every graphics
-- state the draw touched is proven restored against the real driver. The
-- construction/draw failure paths are injected fakes and stay in
-- field_dialogue_renderer_test.lua.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldDialogueController = require("libs.engine.src.FieldDialogueController")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldViewport = require("libs.engine.src.FieldViewport")

local T = {}

local function renderer(scope)
  return scope:own(FieldDialogueRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont() }))
end

function T.loads_the_font_def_and_atlas(scope)
  local dialogue = renderer(scope)

  Assert.equal(dialogue.fontDef.schema, "g4-field-font-v1")
  Assert.notNil(dialogue.atlas)
  Assert.equal(dialogue.atlas:getWidth(), 16)
end

function T.restores_graphics_state_after_draw(scope)
  local lg = love.graphics
  local dialogue = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB")
  local viewport = FieldViewport.new(1280, 720, { mode = "expanded" })

  local canvas = scope:own(lg.newCanvas(64, 64))
  local shader = lg.getShader()
  lg.setCanvas(canvas)
  lg.setBlendMode("add")
  lg.setDepthMode("lequal", true)
  lg.setWireframe(true)
  lg.setMeshCullMode("back")
  lg.setColor(0.2, 0.4, 0.6, 0.8)
  lg.setScissor(4, 8, 32, 16)

  dialogue:draw(controller, viewport)

  FieldDialogueFixture.assertRestoredState(lg, canvas, shader)
end

function T.a_closed_controller_draws_nothing_and_changes_no_state(scope)
  local lg = love.graphics
  local dialogue = renderer(scope)
  local controller = FieldDialogueController.new({
    layout = function()
      return { pages = {}, warnings = {} }
    end,
  })

  lg.setColor(0.1, 0.2, 0.3, 0.4)
  dialogue:draw(controller, FieldViewport.new(960, 720, { mode = "expanded" }))

  Assert.near(lg.getColor(), 0.1, 1e-6)
  Assert.isNil(lg.getShader())
end

function T.draws_inside_the_reference_frame_at_every_host_aspect(scope)
  local dialogue = renderer(scope)

  for _, size in ipairs({ { 960, 720 }, { 1280, 720 }, { 1920, 720 }, { 640, 480 } }) do
    local controller = FieldDialogueFixture.openDialogue("AB")
    local viewport = FieldViewport.new(size[1], size[2], { mode = "expanded" })
    dialogue:draw(controller, viewport)

    local layout = FieldDialogueTheme.layout(viewport.referenceFrame)
    local box = FieldDialogueTheme.screenRect(layout, layout.box)
    local frame = viewport.referenceFrame
    Assert.isTrue(box.x >= frame.x, "box inside frame at " .. size[1] .. "x" .. size[2])
    Assert.isTrue(box.x + box.width <= frame.x + frame.width + 1e-9)
    Assert.isTrue(box.y >= frame.y and box.y + box.height <= frame.y + frame.height + 1e-9)
  end
end

function T.nine_slice_draws_border_and_fill_at_correct_pixels(scope)
  local lg = love.graphics
  local dialogue = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB")
  local viewport = FieldViewport.new(960, 720, { mode = "expanded" })

  local canvas = scope:own(lg.newCanvas(960, 720))
  lg.setCanvas(canvas)
  lg.clear(0, 0, 0, 0)
  dialogue:draw(controller, viewport)
  lg.setCanvas()
  local data = scope:own(canvas:newImageData())

  local layout = FieldDialogueTheme.layout(viewport.referenceFrame)
  local box = FieldDialogueTheme.screenRect(layout, layout.box)
  -- Top border slice (2 reference px tall -> 7.5 screen px).
  local br, bg, bb = data:getPixel(math.floor(box.x + box.width / 2), math.floor(box.y + 3))
  Assert.near(br, 0.16, 0.05, "top border red")
  Assert.near(bg, 0.20, 0.05, "top border green")
  Assert.near(bb, 0.42, 0.05, "top border blue")
  -- Left border slice, vertically centered (clear of the text lines).
  local lr, lgg, lb = data:getPixel(math.floor(box.x + 3), math.floor(box.y + box.height / 2))
  Assert.near(lr, 0.16, 0.05, "left border red")
  Assert.near(lgg, 0.20, 0.05, "left border green")
  Assert.near(lb, 0.42, 0.05, "left border blue")
  -- Center fill below the text lines: the light window color alpha-blended over
  -- the cleared canvas (0.93 * 0.96).
  local fr, fg, fb = data:getPixel(math.floor(box.x + box.width / 2), math.floor(box.y + box.height - 12))
  Assert.near(fr, 0.89, 0.05, "fill red")
  Assert.near(fg, 0.89, 0.05, "fill green")
  Assert.near(fb, 0.93, 0.05, "fill blue")
end

-- Release is the contract here; it is still scoped so a failed assertion does
-- not leak the renderer. The scope's later release exercises repeat safety.
function T.release_frees_the_owned_atlas_and_slice_images(scope)
  local dialogue = scope:own(FieldDialogueRenderer.new({ cacheFs = FieldDialogueFixture.cacheWithFont() }))

  dialogue:release()

  Assert.isNil(dialogue.atlas)
  Assert.isNil(dialogue._sliceImage)
end

-- A renderer built against a cache without the atlas PNG must not report a
-- half-built object: the typed error names the missing artifact.
function T.a_missing_atlas_is_a_typed_error()
  local cache = CacheFs.forVersion("heartgold", FakeCache.new())
  cache:write("data/generated/field/font/font-0.lua", FieldDialogueFixture.encodedFontDef())

  local err = Assert.throws(function()
    FieldDialogueRenderer.new({ cacheFs = cache })
  end)

  Assert.equal(err.code, "FONT_ATLAS_MISSING")
end

return GraphicsSmoke.suite(T)
