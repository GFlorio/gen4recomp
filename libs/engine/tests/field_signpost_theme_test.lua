-- Pure FieldSignpostTheme tests: the signpost frame tilemap (the
-- DrawFrameAndWindow3 composition; the graphic kind adds the divider tile 8
-- to the full-width frame), the wayfinding 6x4 grid blit, and the wipe
-- translation sign -- the hidden -48 BG offset shifts the surface 48px below
-- the bottom of the screen (DS BG y-scroll sign), so the renderer translates
-- by the negation. The full-width placements are the shared DrawFrameAndWindow2
-- tilemap already pinned by field_dialogue_theme_test.lua; this suite pins
-- only what is signpost-specific.

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

-- The wayfinding row (24 tiles, sub_0200EF84) blits as a 6x4 grid: atlas
-- tile row*6+col lands at (region.x + col*8, region.y + row*8).
function T.wayfinding_placements_blit_the_24_tile_row_as_a_6x4_grid()
  local region = { x = 16, y = 152, width = 56, height = 32 }
  local placements = FieldSignpostTheme.wayfindingPlacements(region)
  Assert.equal(#placements, 24)
  for _, placement in ipairs(placements) do
    local row = math.floor(placement.tile / 6)
    local col = placement.tile % 6
    Assert.equal(placement.x, region.x + col * 8, "grid column placement")
    Assert.equal(placement.y, region.y + row * 8, "grid row placement")
  end
  Assert.equal(placements[1].tile, 0)
  Assert.equal(placements[7].tile, 6, "row 1 starts after the six row-0 tiles")
  Assert.equal(placements[24].tile, 23)
end

function T.wayfinding_placements_require_a_region_big_enough_for_the_grid()
  Assert.throws(function()
    FieldSignpostTheme.wayfindingPlacements({ x = 16, y = 152, width = 40, height = 32 })
  end, "a region narrower than the 48px grid must be rejected")
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
