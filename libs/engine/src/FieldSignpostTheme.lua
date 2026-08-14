-- Pure signpost window presentation geometry: the frame tilemap, the
-- wayfinding graphic grid, and the wipe translation of the HGSS signpost
-- window. The signpost is a different window system from ordinary dialogue
-- (src/field/signpost.c, asm/render_window.s at the pinned decomp commit):
-- DrawFrameAndWindow3 draws the full-width DrawFrameAndWindow2 tilemap for
-- every source type, and for types 0/1 additionally reserves the seven-tile
-- wayfinding area -- the 24-tile wayfinding row blits as a 6x4 grid left of
-- the text window and frame tile 8 becomes the divider (sub_0200ECBC +
-- sub_0200EF84). The whole signpost BG layer slides by the logical wipe
-- offset: the DS BG y-scroll register holds the offset, so the hidden -48
-- value shifts the surface 48px down off the bottom of the 192px screen and
-- the renderer translates by its negation. All geometry is pure so the
-- composition is testable headlessly.

local FieldDialogueTheme = require("libs.engine.src.FieldDialogueTheme")

---@class FieldSignpostTheme
---@field WINDOW_BOX FieldDialogueTheme.Rect the full-width signpost frame box (the shared DIALOG_BOX_* rect)
---@field LINE_HEIGHT integer
---@field WAYFINDING_GRID_COLUMNS integer
---@field WAYFINDING_GRID_ROWS integer
---@field colors { marker: number[] }
---@field frameTilePlacements fun(kind: string): { tile: integer, x: integer, y: integer, spanX?: integer, spanY?: integer }[]
---@field wayfindingPlacements fun(region: FieldDialogueTheme.Rect): { tile: integer, x: integer, y: integer }[]
---@field wipeY fun(logicalYOffset: number): number
local FieldSignpostTheme = {}
FieldSignpostTheme.__index = FieldSignpostTheme

-- The signpost frame surrounds the full-width 27x4-tile box for every source
-- type (the DIALOG_BOX_* constants from src/dialog_box.c); types 0/1 only
-- move the text window to the right of the wayfinding area.
FieldSignpostTheme.WINDOW_BOX = FieldDialogueTheme.box

-- Two 16px text lines fill the 32px window height, like the dialogue box.
FieldSignpostTheme.LINE_HEIGHT = FieldDialogueTheme.lineHeight

-- The wayfinding row is 24 tiles and blits as a 6-wide by 4-tall grid
-- (sub_0200EF84: tile base+30 + i*6 + j at (windowX-7+j, windowY+i)).
FieldSignpostTheme.WAYFINDING_GRID_COLUMNS = 6
FieldSignpostTheme.WAYFINDING_GRID_ROWS = 4
FieldSignpostTheme.WAYFINDING_TILES = 24

-- The audited signpost frame tilemap. "full" is the shared
-- DrawFrameAndWindow2 composition around the full-width box (tile 8 never
-- placed); "graphic" (source types 0/1) keeps every placement and inserts
-- tile 8 as the divider right of the six-tile wayfinding graphic.
---@param kind "full"|"graphic"
---@return { tile: integer, x: integer, y: integer, spanX?: integer, spanY?: integer }[]
function FieldSignpostTheme.frameTilePlacements(kind)
  assert(kind == "full" or kind == "graphic", "unknown signpost frame kind " .. tostring(kind))
  local box = FieldSignpostTheme.WINDOW_BOX
  local placements = FieldDialogueTheme.frameTilePlacements(box)
  if kind == "graphic" then
    placements[#placements + 1] = {
      tile = 8,
      x = box.x + FieldSignpostTheme.WAYFINDING_GRID_COLUMNS * 8,
      y = box.y,
      spanY = box.height / 8,
    }
  end
  return placements
end

-- The 24-tile wayfinding row blitted as a 6x4 grid inside the type's graphic
-- region: atlas tile row*6+col at (region.x + col*8, region.y + row*8). The
-- region must hold the 48x32 grid (the 56px reserved area leaves the
-- divider's 8px for the frame).
---@param region FieldDialogueTheme.Rect
---@return { tile: integer, x: integer, y: integer }[]
function FieldSignpostTheme.wayfindingPlacements(region)
  assert(
    type(region) == "table" and region.x and region.y and region.width and region.height,
    "wayfindingPlacements requires the graphic region"
  )
  local gridWidth = FieldSignpostTheme.WAYFINDING_GRID_COLUMNS * 8
  local gridHeight = FieldSignpostTheme.WAYFINDING_GRID_ROWS * 8
  assert(region.width >= gridWidth and region.height >= gridHeight, "the graphic region must hold the wayfinding grid")
  local placements = {}
  for row = 0, FieldSignpostTheme.WAYFINDING_GRID_ROWS - 1 do
    for col = 0, FieldSignpostTheme.WAYFINDING_GRID_COLUMNS - 1 do
      placements[#placements + 1] = {
        tile = row * FieldSignpostTheme.WAYFINDING_GRID_COLUMNS + col,
        x = region.x + col * 8,
        y = region.y + row * 8,
      }
    end
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
