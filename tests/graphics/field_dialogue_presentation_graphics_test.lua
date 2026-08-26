-- Contract scenarios for the reusable host dialogue presentation. These run
-- at the graphics boundary because the behavior under test is the production
-- renderer's transform and draw contract.

local Assert = require("tests.support.Assert")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")
local FieldTextRenderer = require("libs.engine.src.FieldTextRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FakeGraphics = require("tests.support.FakeGraphics")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

local function renderer(scope)
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local graphics = FakeGraphics.new()
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cache, graphics = graphics }))
  local dialogue = scope:own(FieldDialogueRenderer.new({
    cacheFs = cache,
    manifest = FieldUiFixture.manifest(),
    text = text,
    graphics = graphics,
  }))
  return dialogue, graphics
end

T["authentic_window_renders_inside_arbitrary_host_bounds"] = function(scope)
  local dialogue, graphics = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local presentation = {
    bounds = { x = 37, y = 11, width = 900, height = 420 },
    origin = { x = 359, y = 383 },
    scale = 1.640625,
    outerRect = { x = 359, y = 383, width = 420, height = 78.75 },
    box = { x = 16, y = 8, width = 216, height = 32 },
    text = { x = 26, y = 8, width = 196, height = 32 },
    cursor = { x = 240, y = 24, width = 16, height = 16 },
    lineHeight = 16,
  }

  dialogue:draw(controller, presentation)

  Assert.deepEqual(graphics.transforms, {
    { "translate", presentation.origin.x, presentation.origin.y },
    { "scale", presentation.scale, presentation.scale },
  })
  Assert.isTrue(#graphics.draws > 0, "the active dialogue must draw its frame")
end

T["field_dialogue_remains_geometrically_and_behaviorally_identical"] = function()
  local layout = FieldDialogueTheme.layout({ x = 90, y = 40, width = 700, height = 500 }, 2)

  Assert.equal(layout.box.x, 16)
  Assert.equal(layout.box.y, 152)
  Assert.equal(layout.box.width, 216)
  Assert.equal(layout.box.height, 32)
  Assert.equal(layout.text.width, 216)
  Assert.equal(layout.lineHeight, 16)
  Assert.equal(layout.scale, 2)
  Assert.equal(layout.origin.x, 184)
  Assert.equal(layout.origin.y, 156)
end

T["invalid_presentations_fail_before_partial_drawing"] = function(scope)
  local dialogue = renderer(scope)
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local ok, err = pcall(function()
    dialogue:draw(controller, {
      bounds = { x = 0, y = 0, width = 640, height = 480 },
      origin = { x = 0, y = 0 },
    })
  end)
  Assert.isFalse(ok, "a malformed active presentation must be rejected")
  Assert.isTrue(
    tostring(err):find("presentation", 1, true) ~= nil,
    "malformed active presentations must fail at the presentation boundary"
  )

  local bounds = { x = 10, y = 20, width = 640, height = 480 }
  local ok = pcall(function()
    FieldDialogueTheme.layout(bounds, 0)
  end)
  Assert.isFalse(ok, "zero exact scale must be rejected before drawing")

  local okNaN = pcall(function()
    FieldDialogueTheme.layout(bounds, 0 / 0)
  end)
  Assert.isFalse(okNaN, "NaN exact scale must be rejected before drawing")

  local okMissing = pcall(function()
    ---@diagnostic disable-next-line: missing-fields
    FieldDialogueTheme.layout({ x = 0, y = 0, width = 640 }, 1)
  end)
  Assert.isFalse(okMissing, "incomplete bounds must be rejected before drawing")
end

return GraphicsSmoke.suite(T)
