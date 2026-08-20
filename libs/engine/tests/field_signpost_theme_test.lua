-- Pure FieldSignpostTheme tests: the signpost frame tilemap (the
-- DrawFrameAndWindow3 composition; the graphic kind adds the divider tile 8
-- to the full-width frame), and the wipe translation sign -- the hidden -48
-- BG offset shifts the surface 48px below the bottom of the screen (DS BG
-- y-scroll sign), so the renderer translates by the negation. The full-width
-- placements are the shared DrawFrameAndWindow2 tilemap already pinned by
-- field_dialogue_theme_test.lua; this suite pins only what is signpost-specific.
-- The precomposed wayfinding graphic is a single 48x32 surface; the theme
-- owns its graphic width for the divider placement.

local Assert = require("tests.support.Assert")
local FieldSignpostTheme = require("libs.engine.src.FieldSignpostTheme")

local T = {}

-- The graphic kind keeps every full-width placement and inserts tile 8 as
-- the divider at the left of the text window: source sub_0200ECBC fills tile
-- base+8 at (windowX-9+8, windowY) spanning the window height, i.e. x=64 in
-- reference pixels (box.x + 6 tiles of wayfinding graphic).
function T.graphic_kind_adds_the_divider_tile_to_the_full_width_frame()
  local function findDivider(placements)
    for _, placement in ipairs(placements) do
      if placement.tile == 8 then
        return placement
      end
    end
    return nil
  end
  local full = FieldSignpostTheme.frameTilePlacements("full")
  local graphic = FieldSignpostTheme.frameTilePlacements("graphic")
  Assert.equal(#graphic, #full + 1, "the graphic kind adds exactly one tile")
  for _, placement in ipairs(full) do
    local found = false
    for _, other in ipairs(graphic) do
      if other.tile == placement.tile then
        found = true
        Assert.deepEqual(other, placement, "the full-width placements are preserved")
        break
      end
    end
    Assert.isTrue(found, "tile " .. tostring(placement.tile) .. " survives into the graphic kind")
  end
  local divider = assert(findDivider(graphic), "tile 8 is the divider")
  local box = FieldSignpostTheme.WINDOW_BOX
  Assert.equal(divider.x, box.x + 6 * 8, "the divider sits right of the 6-tile wayfinding graphic")
  Assert.equal(divider.y, box.y)
  Assert.equal(divider.spanY, box.height / 8, "the divider spans the window height")
  Assert.isNil(divider.spanX)
end

function T.rejects_an_unknown_frame_kind()
  local unknown = "fancy" ---@type any
  Assert.throws(function()
    FieldSignpostTheme.frameTilePlacements(unknown)
  end, "unknown frame kinds must be rejected")
end

function T.wayfinding_graphic_width_is_48()
  Assert.equal(FieldSignpostTheme.WAYFINDING_WIDTH, 48, "precomposed surface is 48px wide")
  Assert.equal(FieldSignpostTheme.WAYFINDING_HEIGHT, 32, "precomposed surface is 32px tall")
end

function T.divider_sits_right_of_the_48px_wayfinding_graphic()
  local box = FieldSignpostTheme.WINDOW_BOX
  local graphic = FieldSignpostTheme.frameTilePlacements("graphic")
  local divider = nil
  for _, placement in ipairs(graphic) do
    if placement.tile == 8 then
      divider = placement
      break
    end
  end
  divider = assert(divider)
  Assert.equal(divider.x, box.x + FieldSignpostTheme.WAYFINDING_WIDTH, "divider at graphic x+48")
end

-- The wipe translation sign: the BG y-scroll register is set to the logical
-- offset, so the hidden -48 value moves the whole layer 48px down -- off the
-- bottom of the 192px screen -- and the wipe-in rise to 0 slides it up.
function T.wipe_translation_moves_the_hidden_surface_below_the_screen()
  Assert.equal(FieldSignpostTheme.wipeY(-48), 48, "the hidden offset renders 48px below the rest position")
  Assert.equal(FieldSignpostTheme.wipeY(-32), 32)
  Assert.equal(FieldSignpostTheme.wipeY(-16), 16)
  Assert.equal(FieldSignpostTheme.wipeY(0), 0)
end

return { tests = T }
