local Assert = require("tests.support.Assert")
local DialoguePresentationLayout = require("libs.hgss.src.ui.DialoguePresentationLayout")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

-- Source placement from generated field-UI manifest.
local function sourcePlacement()
  local m = FieldUiFixture.manifest()
  return m.dialogueFrames.continueCursor.placement
end

local function disjoint(a, b)
  return a.x + a.width <= b.x or b.x + b.width <= a.x or a.y + a.height <= b.y or b.y + b.height <= a.y
end

-- Ordinary field and compact Oak layouts must map the same source placement
-- through their window geometry and reserve text space.
T["cursor_is_source_placed_and_text_does_not_overlap_for_both_presentations"] = function()
  local placement = sourcePlacement()
  Assert.equal(placement.x, 240)
  Assert.equal(placement.y, 168)
  Assert.equal(placement.width, 16)
  Assert.equal(placement.height, 16)

  -- Ordinary field: wide bounds resembling FieldState worldViewport
  local ordinary = DialoguePresentationLayout.compute({ x = 37, y = 11, width = 900, height = 420 }, {
    cursorPlacement = placement,
  })
  -- Compact Oak: host-owned outerRect scale path exercises compact geometry
  local compact = DialoguePresentationLayout.compute({ x = 0, y = 0, width = 390, height = 844 }, {
    cursorPlacement = placement,
  })

  for _, pres in ipairs({ ordinary, compact }) do
    -- Cursor must be manifest-sized in local reference space (no invented 10x8)
    Assert.equal(pres.cursor.width, placement.width, "cursor width must be source width")
    Assert.equal(pres.cursor.height, placement.height, "cursor height must be source height")
    -- Text must not intersect cursor (reservation, not clipping)
    Assert.isTrue(disjoint(pres.text, pres.cursor), "text and cursor must be disjoint so glyphs never draw underneath")
  end

  -- Inverse-mapping must yield source placement relationship for both presentations.
  -- Local cursor is in the layout's 256x48 reference; source placement is in 256x192.
  -- The strip's Y offset is 192-48=144, so expected local Y is sourceY-144.
  local expectedLocal = { x = placement.x, y = placement.y - 144, width = 16, height = 16 }
  for _, pres in ipairs({ ordinary, compact }) do
    Assert.equal(
      pres.cursor.x,
      expectedLocal.x,
      "compact/ordinary cursor X must be source-derived, not a magic constant"
    )
    Assert.equal(pres.cursor.y, expectedLocal.y, "compact/ordinary cursor Y must be source-derived")
  end

  -- Compact must not use an independent magic position
  Assert.equal(ordinary.cursor.x, compact.cursor.x, "compact and ordinary must share the source-derived cursor X")
  Assert.equal(ordinary.cursor.y, compact.cursor.y, "compact and ordinary must share the source-derived cursor Y")
end

-- Renderer must draw cursor at layout rectangle with manifest phase quad, and must not
-- invent timing or position. This is a smoke-level passive-renderer check complementing
-- the layout geometry above.
T["renderer_is_passive_and_uses_layout_cursor"] = function(scope)
  local FakeGraphics = require("tests.support.FakeGraphics")
  local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
  local FieldDialogueRenderer = require("libs.hgss.src.ui.FieldDialogueRenderer")
  local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")

  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local graphics = FakeGraphics.new()
  local text = scope:own(FieldTextRenderer.new({ cacheFs = cache, graphics = graphics }))
  local renderer = scope:own(FieldDialogueRenderer.new({
    cacheFs = cache,
    manifest = FieldUiFixture.manifest(),
    text = text,
    graphics = graphics,
  }))
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  -- advance to waiting so cursor is visible
  controller:step({})
  for _ = 1, 40 do
    if controller:status().waiting then
      break
    end
    controller:step({})
  end
  local status = controller:status()
  -- If fixture text still revealing, force waiting via prompt layout controller
  if not status.waiting then
    local FieldDialogueController = require("libs.hgss.src.ui.FieldDialogueController")
    local ctrl2 = FieldDialogueController.new({
      layout = function()
        return {
          pages = {
            {
              lines = {
                {
                  tokens = { { kind = "glyph", code = 1, text = "A", raw = { 1 } } },
                  width = 6,
                  lineHeight = 8,
                  lineSpacing = 0,
                },
              },
              breakKind = "prompt",
            },
          },
          warnings = {},
          lineHeight = 8,
          lineSpacing = 0,
        }
      end,
      policy = { interGlyphDelay = 0, glyphBudget = 1, abAcceleration = false },
      continueCursor = { cycle = { 0, 1, 2, 1 }, framePrinterTicks = 9 },
    })
    ctrl2:open({
      id = "smoke-wait",
      message = {
        bankId = 1,
        messageId = 1,
        text = "A",
        tokens = { { kind = "glyph", code = 1, text = "A", raw = { 1 } } },
        hadUnresolvedSubstitutions = false,
      },
      allowCancel = false,
      frameIndex = 0,
    })
    for _ = 1, 10 do
      if ctrl2:status().waiting then
        break
      end
      ctrl2:step({})
    end
    controller = ctrl2
    status = controller:status()
  end
  Assert.isTrue(status.waiting, "cursor must be visible")

  local presentation = DialoguePresentationLayout.compute({ x = 37, y = 11, width = 900, height = 420 }, {
    cursorPlacement = sourcePlacement(),
  })
  local beforePhase = status.cursorPhase
  renderer:draw(controller, presentation)
  local draws = graphics.draws
  local last = draws[#draws]
  Assert.notNil(last, "cursor draw must occur")
  Assert.equal(
    last.x,
    presentation.cursor.x,
    "renderer must draw cursor at layout rectangle, not source placement nor magic offset"
  )
  Assert.equal(last.y, presentation.cursor.y, "renderer must draw cursor at layout rectangle")
  -- Repeated draws must not advance phase
  local innerBefore = controller:status().cursorPhase
  renderer:draw(controller, presentation)
  Assert.equal(controller:status().cursorPhase, innerBefore, "renderer draw must not mutate controller phase")
  Assert.equal(beforePhase, innerBefore, "phase is controller-owned")
end

return GraphicsSmoke.suite(T)
