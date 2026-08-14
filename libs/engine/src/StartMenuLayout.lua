-- StartMenuLayout places the canonical 256x192 Start Menu surface on a
-- ScreenTopology without reflowing its internal geometry: only the whole
-- surface is positioned and scaled. resolve() returns one complete placement
-- record ({ surfaceId, frame, scale, logicalWidth, logicalHeight }): the
-- auxiliary display is the menu screen when one exists; a landscape host gets
-- a side panel right of the 4:3 world reference frame (the ultrawide model —
-- never stretched across unused horizontal space); a single 4:3 host is a
-- full-surface modal overlay; a portrait host partitions vertically with the
-- menu as a full-width lower panel, subject to minimum usable region sizes.
-- The canonical surface is always scaled uniformly, centered in the chosen
-- safe rectangle, and rounded to integer pixels at the host boundary. Hit
-- testing and rendering consume the same record through hostToLogical(), so
-- there is never a second set of scaled rectangles. Pure: no LÖVE, no I/O.

local StartMenuLayout = {}

local CANONICAL_WIDTH = 256
local CANONICAL_HEIGHT = 192
local WORLD_ASPECT = 4 / 3

-- Minimum usable region sizes: the landscape side panel must be at least half
-- the canonical width, and a portrait partition must leave both the world
-- region and the lower panel at least half the canonical height. Below those
-- floors the layout falls back to the centered uniform fit.
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

-- The landscape side panel: the world reference frame occupies the left
-- 4:3-of-height region, the menu panel is the remaining width, and the menu
-- scales to the panel height while staying 4:3 internally. Returns nil when
-- the panel is too narrow to be usable.
local function sidePanel(safe)
  local worldFrameWidth = safe.height * WORLD_ASPECT
  local panelWidth = safe.width - worldFrameWidth
  if panelWidth < MIN_SIDE_PANEL_WIDTH then
    return nil
  end
  local scale = math.min(panelWidth / CANONICAL_WIDTH, safe.height / CANONICAL_HEIGHT)
  local width = math.floor(CANONICAL_WIDTH * scale)
  local height = math.floor(CANONICAL_HEIGHT * scale)
  local x = math.floor(safe.x + worldFrameWidth + (panelWidth - width) / 2)
  local y = safe.y + math.floor((safe.height - height) / 2)
  return scale, width, height, x, y
end

-- The portrait lower panel: the world stays above and the menu becomes a
-- full-width bottom panel. Returns nil when either region would drop below
-- its minimum usable size.
local function bottomPanel(safe)
  local scale = safe.width / CANONICAL_WIDTH
  local height = math.floor(CANONICAL_HEIGHT * scale)
  local worldHeight = safe.height - height
  if height < MIN_PANEL_HEIGHT or worldHeight < MIN_WORLD_HEIGHT then
    return nil
  end
  return scale, safe.width, height, safe.x, safe.y + safe.height - height
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

local function panelOrCentered(builder, safe)
  local scale, width, height, x, y = builder(safe)
  if scale == nil then
    return centeredFit(safe)
  end
  return scale, width, height, x, y
end

-- Resolves the complete placement record for the canonical 256x192 Start
-- Menu surface. Internal menu geometry is invariant; only the whole surface
-- is positioned and scaled.

---@param topology ScreenTopology
---@return StartMenuLayout.Placement
function StartMenuLayout.resolve(topology)
  local surface = StartMenuLayout.selectSurface(topology)
  local safe = assertSafeRect(surface)
  local scale, width, height, x, y
  if surface.role == "auxiliary" then
    scale, width, height, x, y = centeredFit(safe)
  elseif safe.width < safe.height then
    scale, width, height, x, y = panelOrCentered(bottomPanel, safe)
  else
    scale, width, height, x, y = panelOrCentered(sidePanel, safe)
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
