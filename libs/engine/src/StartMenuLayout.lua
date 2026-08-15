-- StartMenuLayout places the canonical 256x192 Start Menu surface on a
-- ScreenTopology without reflowing its internal geometry: only the whole
-- surface is positioned and scaled. resolve() takes the actual world
-- reference frame the FieldViewport computes and returns one complete
-- placement record ({ surfaceId, frame, scale, logicalWidth,
-- logicalHeight }): the auxiliary display is the menu screen when one
-- exists; a landscape host gets a side panel in the real right gutter
-- (reference frame right edge to safe right); a single 4:3 host is a
-- full-surface modal overlay; a portrait host partitions vertically with
-- the menu as a full-width lower panel below the reference frame, subject
-- to minimum usable region sizes. The canonical surface is always scaled
-- uniformly, centered in the chosen region, and rounded to integer pixels
-- at the host boundary. Hit testing and rendering consume the same record
-- through hostToLogical(), so there is never a second set of scaled
-- rectangles. Pure: no LÖVE, no I/O.

local StartMenuLayout = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192

-- Minimum usable region sizes: the landscape side panel must be at least
-- half the canonical width, and a portrait partition must leave both the
-- world reference frame and the lower panel at least half the canonical
-- height. Below those floors the layout falls back to the centered uniform
-- fit.
local MIN_SIDE_PANEL_WIDTH = CANONICAL_WIDTH / 2
local MIN_PANEL_HEIGHT = CANONICAL_HEIGHT / 2
local MIN_WORLD_HEIGHT = CANONICAL_HEIGHT / 2

local function assertFiniteNumber(value, name)
  assert(
    type(value) == "number" and value == value and value > -math.huge and value < math.huge,
    name .. " must be finite"
  )
end

local function assertInteger(value, name)
  assertFiniteNumber(value, name)
  assert(value == math.floor(value), name .. " must be an integer")
end

-- The chosen surface's safe rectangle must be an integer host-space rect: the
-- deterministic rounding contract floors at the host boundary, so fractional
-- inputs cannot produce a frame that stays inside the safe bounds.
local function assertSafeRect(surface)
  assert(type(surface) == "table" and type(surface.safeRect) == "table", "the placed surface needs a safe rect")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assertInteger(surface.safeRect[field], "safe rect " .. field)
  end
  return surface.safeRect
end

-- The placement surface: the auxiliary display when one exists, else the
-- first surface, mirroring the sibling MenuLayout surface selection.
---@param topology ScreenTopology
---@return ScreenTopology.Surface
function StartMenuLayout.selectSurface(topology)
  assert(
    type(topology) == "table" and type(topology.surfaces) == "table" and #topology.surfaces > 0,
    "StartMenuLayout requires a ScreenTopology"
  )
  for _, surface in ipairs(topology.surfaces) do
    if surface.role == "auxiliary" then
      return surface
    end
  end
  return topology.surfaces[1]
end

-- The uniform centered fit inside the safe rectangle: the canonical surface
-- scaled by min(safeWidth/256, safeHeight/192) and centered, with every frame
-- value floored at the host boundary so the frame stays inside safe bounds.
local function centeredFit(safe)
  local scale = math.min(safe.width / CANONICAL_WIDTH, safe.height / CANONICAL_HEIGHT)
  local width = math.floor(CANONICAL_WIDTH * scale)
  local height = math.floor(CANONICAL_HEIGHT * scale)
  return scale,
    width,
    height,
    safe.x + math.floor((safe.width - width) / 2),
    safe.y + math.floor((safe.height - height) / 2)
end

-- The landscape side panel: the actual right gutter -- the world reference
-- frame's right edge to the safe right -- and the menu scales into it while
-- staying 4:3 internally. Returns nil when the gutter is too narrow to be
-- usable.
---@param safe table
---@param referenceFrame table
local function sidePanel(safe, referenceFrame)
  local gutterStart = referenceFrame.x + referenceFrame.width
  local panelWidth = safe.x + safe.width - gutterStart
  if panelWidth < MIN_SIDE_PANEL_WIDTH then
    return nil
  end
  local scale = math.min(panelWidth / CANONICAL_WIDTH, safe.height / CANONICAL_HEIGHT)
  local width = math.floor(CANONICAL_WIDTH * scale)
  local height = math.floor(CANONICAL_HEIGHT * scale)
  local x = math.floor(gutterStart + (panelWidth - width) / 2)
  local y = safe.y + math.floor((safe.height - height) / 2)
  return scale, width, height, x, y
end

-- The portrait lower panel: the region below the world reference frame
-- becomes a full-width bottom panel. Returns nil when either region would
-- drop below its minimum usable size.
---@param safe table
---@param referenceFrame table
local function bottomPanel(safe, referenceFrame)
  local panelTop = math.floor(referenceFrame.y + referenceFrame.height)
  local panelHeight = safe.y + safe.height - panelTop
  if referenceFrame.height < MIN_WORLD_HEIGHT then
    return nil
  end
  local scale = math.min(safe.width / CANONICAL_WIDTH, panelHeight / CANONICAL_HEIGHT)
  local height = math.floor(CANONICAL_HEIGHT * scale)
  if height < MIN_PANEL_HEIGHT then
    return nil
  end
  local width = math.floor(CANONICAL_WIDTH * scale)
  local x = safe.x + math.floor((safe.width - width) / 2)
  local y = panelTop + math.floor((panelHeight - height) / 2)
  return scale, width, height, x, y
end

---@class StartMenuLayout.Placement
---@field surfaceId string
---@field frame ScreenTopology.Rectangle
---@field scale number
---@field logicalWidth integer
---@field logicalHeight integer

-- Resolves the chosen partition (bottom panel / side panel) or falls back to
-- the centered uniform fit when the partition is unusable. The helper calls
-- return multiple values, so they must not flow through `or`, which would
-- collapse them to one.

local function panelOrCentered(builder, safe, referenceFrame)
  local scale, width, height, x, y = builder(safe, referenceFrame)
  if scale == nil then
    return centeredFit(safe)
  end
  return scale, width, height, x, y
end

-- Resolves the complete placement record for the canonical 256x192 Start
-- Menu surface against the actual world reference frame (FieldViewport's
-- referenceFrame). Internal menu geometry is invariant; only the whole
-- surface is positioned and scaled.

---@param topology ScreenTopology
---@param referenceFrame { x: number, y: number, width: number, height: number } the world reference frame
---@return StartMenuLayout.Placement
function StartMenuLayout.resolve(topology, referenceFrame)
  assert(
    type(referenceFrame) == "table"
      and type(referenceFrame.x) == "number"
      and type(referenceFrame.y) == "number"
      and type(referenceFrame.width) == "number"
      and type(referenceFrame.height) == "number",
    "StartMenuLayout requires the world reference frame"
  )
  local surface = StartMenuLayout.selectSurface(topology)
  local safe = assertSafeRect(surface)
  local scale, width, height, x, y
  if surface.role == "auxiliary" then
    scale, width, height, x, y = centeredFit(safe)
  elseif safe.width < safe.height then
    scale, width, height, x, y = panelOrCentered(bottomPanel, safe, referenceFrame)
  else
    scale, width, height, x, y = panelOrCentered(sidePanel, safe, referenceFrame)
  end
  return {
    surfaceId = surface.id,
    frame = { x = x, y = y, width = width, height = height },
    scale = scale,
    logicalWidth = CANONICAL_WIDTH,
    logicalHeight = CANONICAL_HEIGHT,
  }
end

-- Maps a host-space point to canonical logical coordinates (0..255 x 0..191)
-- through the placement record. Hit testing first rejects every point outside
-- the frame, then maps inside points; the transform is the exact inverse of
-- the render placement (frame origin + canonical * scale), so hit testing and
-- rendering share one record with no second set of scaled rectangles.

---@param placement StartMenuLayout.Placement
---@param hostX number
---@param hostY number
---@return number? canonicalX
---@return number? canonicalY
function StartMenuLayout.hostToLogical(placement, hostX, hostY)
  assert(
    type(placement) == "table" and type(placement.frame) == "table" and type(placement.scale) == "number",
    "hostToLogical requires a placement record"
  )
  assertFiniteNumber(hostX, "hostX")
  assertFiniteNumber(hostY, "hostY")
  local frame = placement.frame
  if hostX < frame.x or hostY < frame.y or hostX >= frame.x + frame.width or hostY >= frame.y + frame.height then
    return nil
  end
  return (hostX - frame.x) / placement.scale, (hostY - frame.y) / placement.scale
end

return StartMenuLayout
