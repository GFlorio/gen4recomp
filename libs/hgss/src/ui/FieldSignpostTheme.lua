-- Pure signpost window presentation geometry: the frame tilemap and the
-- wipe translation of the HGSS signpost window. The signpost is a different
-- window system from ordinary dialogue (src/field/signpost.c,
-- asm/render_window.s at the pinned decomp commit): DrawFrameAndWindow3 draws
-- the full-width DrawFrameAndWindow2 tilemap for every source type, and for
-- types 0/1 additionally reserves the seven-tile wayfinding area -- the
-- precomposed 48x32 final wayfinding surface left of the text window and
-- frame tile 8 becomes the divider (sub_0200ECBC + sub_0200EF84). The
-- wayfinding source is 24 tiles arranged 6x4 at build time; runtime draws
-- one rect. The whole signpost BG layer slides by the logical wipe offset:
-- the DS BG y-scroll register holds the offset, so the hidden -48 value
-- shifts the surface 48px down off the bottom of the 192px screen and the
-- renderer translates by its negation. All geometry is pure so the
-- composition is testable headlessly.

local FieldDialogueTheme = require("libs.hgss.src.ui.FieldDialogueTheme")

---@class FieldSignpostTheme
---@field WINDOW_BOX FieldDialogueTheme.Rect the full-width signpost frame box (the shared DIALOG_BOX_* rect)
---@field LINE_HEIGHT integer
---@field WAYFINDING_WIDTH integer width of the precomposed wayfinding graphic
---@field WAYFINDING_HEIGHT integer height of the precomposed wayfinding graphic
---@field frameTilePlacements fun(kind: string): { tile: integer, x: integer, y: integer, spanX?: integer, spanY?: integer }[]
---@field wipeY fun(logicalYOffset: number): number
local FieldSignpostTheme = {}

-- The signpost frame surrounds the full-width 27x4-tile box for every source
-- type (the DIALOG_BOX_* constants from src/dialog_box.c); types 0/1 only
-- move the text window to the right of the wayfinding area.
FieldSignpostTheme.WINDOW_BOX = FieldDialogueTheme.box

-- Two 16px text lines fill the 32px window height, like the dialogue box.
FieldSignpostTheme.LINE_HEIGHT = FieldDialogueTheme.lineHeight

-- The precomposed wayfinding surface: 48x32 (6 columns x 4 rows of 8px
-- tiles). Runtime draws one rect; the 56px reserved graphic region leaves
-- 8px for the frame divider.
FieldSignpostTheme.WAYFINDING_WIDTH = 48
FieldSignpostTheme.WAYFINDING_HEIGHT = 32

-- The audited signpost frame tilemap. "full" is the shared
-- DrawFrameAndWindow2 composition around the full-width box (tile 8 never
-- placed); "graphic" (source types 0/1) keeps every placement and inserts
-- tile 8 as the divider right of the wayfinding graphic.
---@param kind "full"|"graphic"
---@return { tile: integer, x: integer, y: integer, spanX?: integer, spanY?: integer }[]
function FieldSignpostTheme.frameTilePlacements(kind)
  assert(kind == "full" or kind == "graphic", "unknown signpost frame kind " .. tostring(kind))
  local box = FieldSignpostTheme.WINDOW_BOX
  ---@cast box FieldDialogueTheme.Rect
  local placements = FieldDialogueTheme.frameTilePlacements(box)
  if kind == "graphic" then
    local x = box.x + FieldSignpostTheme.WAYFINDING_WIDTH
    local y = box.y
    local spanY = box.height / 8
    ---@cast x integer
    ---@cast y integer
    ---@cast spanY integer
    placements[#placements + 1] = {
      tile = 8,
      x = x,
      y = y,
      spanY = spanY,
    }
  end
  return placements
end

-- Maps the logical wipe offset to the reference-canvas translation: the BG
-- y-scroll register holds the offset, so the hidden -48 value renders the
-- whole layer 48px below its rest position (off the bottom of the screen).
---@param logicalYOffset number
---@return number
function FieldSignpostTheme.wipeY(logicalYOffset)
  assert(type(logicalYOffset) == "number", "wipeY requires the logical offset")
  return -logicalYOffset
end

return FieldSignpostTheme
