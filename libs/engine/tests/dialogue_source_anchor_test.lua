-- Source-space decomposition of the standard field dialogue's horizontal
-- placement: the frame/content left edge and the first text pen position are
-- captured independently, before any host scaling, through the exact
-- collaborator the running game uses to place a modal field dialogue
-- (DialoguePresentationLayout.compute, the same call FieldState makes every
-- frame). A synthetic glyph with an opaque pixel at local x 0 and no leading
-- transparent column then proves the shared FieldTextRenderer draws that ink
-- exactly at the supplied pen x, so any remaining bias cannot be blamed on
-- the glyph draw path.

local Assert = require("tests.support.Assert")
local DialoguePresentationLayout = require("libs.engine.src.DialoguePresentationLayout")
local FieldDialogueRenderer = require("libs.engine.src.FieldDialogueRenderer")
local FieldTextRenderer = require("libs.engine.src.FieldTextRenderer")
local FieldDialogueFixture = require("tests.support.FieldDialogueFixture")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local FakeGraphics = require("tests.support.FakeGraphics")

local T = {}

local CURSOR_PLACEMENT = FieldUiFixture.manifest().dialogueFrames.continueCursor.placement

-- The standard HGSS message box is created at tile x 2 (src/field/
-- scrcmd_message.c) and prints at local (0,0), so the box left edge and the
-- first glyph pen both sit at source x 16 with no additional inset.
local STANDARD_WINDOW_SOURCE_X = 16

function T.standard_window_and_pen_source_x_have_no_added_inset()
  local presentation = DialoguePresentationLayout.compute(
    { x = 0, y = 0, width = 256, height = 48 },
    { scale = 1, cursorPlacement = CURSOR_PLACEMENT }
  )

  Assert.equal(presentation.box.x, STANDARD_WINDOW_SOURCE_X, "frame/content left edge is source x 16")
  Assert.equal(
    presentation.text.x,
    STANDARD_WINDOW_SOURCE_X,
    "first text pen x must equal the window origin: HGSS prints at local (0,0), so no inset is added here"
  )
end

-- A minimal fixture renderer built the same way the dialogue smoke suites
-- build one, but with a font atlas swapped for a synthetic single glyph that
-- is opaque at its own local x 0 with no leading transparent column, so the
-- recorded draw position is an exact proxy for the pen x the renderer
-- received.
local function fixtureRenderer()
  local cache = FieldUiFixture.cacheWithFontAndFrames()
  local graphics = FakeGraphics.new()
  local text = FieldTextRenderer.new({ cacheFs = cache, graphics = graphics })
  local dialogue = FieldDialogueRenderer.new({
    cacheFs = cache,
    manifest = FieldUiFixture.manifest(),
    text = text,
    graphics = graphics,
  })
  return dialogue, text, graphics
end

function T.synthetic_zero_bearing_glyph_draws_exactly_at_the_presentation_pen_x()
  local dialogue, text, graphics = fixtureRenderer()
  local controller = FieldDialogueFixture.openDialogue("AB", 0)
  local presentation = DialoguePresentationLayout.compute(
    { x = 0, y = 0, width = 256, height = 48 },
    { scale = 1, cursorPlacement = CURSOR_PLACEMENT }
  )

  -- Reveal both fixture glyphs (the fixture's typewriter is fixed-tick and
  -- outlasts every policy's inter-glyph delay well before 30 ticks) before
  -- the single draw this scenario inspects.
  for _ = 1, 30 do
    controller:step({})
  end
  dialogue:draw(controller, presentation)

  local firstGlyphDraw
  for _, draw in ipairs(graphics.draws) do
    if draw.image == text._atlas then
      firstGlyphDraw = draw
      break
    end
  end
  Assert.notNil(firstGlyphDraw, "the renderer must draw at least one glyph quad from the shared text atlas")
  Assert.equal(
    firstGlyphDraw.x,
    presentation.text.x,
    "FieldTextRenderer draws the first glyph exactly at the pen x the presentation computed; "
      .. "the renderer adds no compensating offset of its own"
  )

  dialogue:release()
  text:release()
end

return { tests = T }
