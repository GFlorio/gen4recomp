-- ScreenTopology describes display surfaces and their usable regions without
-- making any menu-placement or rendering decisions.

---@class ScreenTopology
---@field surfaces ScreenTopology.Surface[]
local ScreenTopology = {}

local ROLES = {
  world = true,
  auxiliary = true,
}

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function assertRectangle(rectangle, name)
  assert(type(rectangle) == "table", name .. " must be a rectangle")
  assert(isFiniteNumber(rectangle.x), name .. ".x must be finite")
  assert(isFiniteNumber(rectangle.y), name .. ".y must be finite")
  assert(isFiniteNumber(rectangle.width) and rectangle.width > 0, name .. ".width must be positive and finite")
  assert(isFiniteNumber(rectangle.height) and rectangle.height > 0, name .. ".height must be positive and finite")
end

local function contains(outer, inner)
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

local function copyRectangle(rectangle)
  return {
    x = rectangle.x,
    y = rectangle.y,
    width = rectangle.width,
    height = rectangle.height,
  }
end

local function assertArray(values, name)
  assert(type(values) == "table", name .. " must be an array")
  for key in pairs(values) do
    assert(type(key) == "number" and key > 0 and key % 1 == 0 and key <= #values, name .. " must be an array")
  end
  for index = 1, #values do
    assert(values[index] ~= nil, name .. " must be an array")
  end
end

local function copyOccupiedRegions(regions, safeRect, name)
  if regions == nil then
    regions = {}
  end
  assertArray(regions, name .. ".occupiedRegions")
  local copied = {}
  for index, region in ipairs(regions) do
    local regionName = name .. ".occupiedRegions[" .. index .. "]"
    assertRectangle(region, regionName)
    assert(contains(safeRect, region), regionName .. " must be inside the safe rectangle")
    copied[index] = copyRectangle(region)
  end
  return copied
end

local function copySurface(surface, index, ids)
  local name = "surfaces[" .. index .. "]"
  assert(type(surface) == "table", name .. " must be a table")
  assert(type(surface.id) == "string" and surface.id ~= "", name .. ".id must be a non-empty string")
  assert(ids[surface.id] == nil, "surface ids must be unique")
  ids[surface.id] = true
  assertRectangle(surface.rect, name .. ".rect")
  assert(ROLES[surface.role], name .. ".role must be world or auxiliary")
  assert(type(surface.touch) == "boolean", name .. ".touch must be boolean")

  local safeRect = surface.safeRect
  if safeRect == nil then
    safeRect = surface.rect
  end
  assertRectangle(safeRect, name .. ".safeRect")
  assert(contains(surface.rect, safeRect), name .. ".safeRect must be inside the surface rectangle")

  return {
    id = surface.id,
    rect = copyRectangle(surface.rect),
    safeRect = copyRectangle(safeRect),
    touch = surface.touch,
    role = surface.role,
    occupiedRegions = copyOccupiedRegions(surface.occupiedRegions, safeRect, name),
  }
end

---@param spec { surfaces: ScreenTopology.SurfaceSpec[] }
---@return ScreenTopology
function ScreenTopology.new(spec)
  assert(type(spec) == "table", "topology spec must be a table")
  assertArray(spec.surfaces, "topology.surfaces")
  assert(#spec.surfaces > 0, "topology requires at least one surface")

  local ids = {}
  local surfaces = {}
  for index, surface in ipairs(spec.surfaces) do
    surfaces[index] = copySurface(surface, index, ids)
  end
  return { surfaces = surfaces }
end

---@param surface ScreenTopology.SurfaceSpec
---@return ScreenTopology
function ScreenTopology.oneDisplay(surface)
  return ScreenTopology.new({ surfaces = { surface } })
end

---@param main ScreenTopology.SurfaceSpec
---@param auxiliary ScreenTopology.SurfaceSpec
---@return ScreenTopology
function ScreenTopology.dualDisplay(main, auxiliary)
  assert(type(main) == "table" and main.role == "world", "dual display main surface must have world role")
  assert(
    type(auxiliary) == "table" and auxiliary.role == "auxiliary",
    "dual display auxiliary surface must have auxiliary role"
  )
  return ScreenTopology.new({ surfaces = { main, auxiliary } })
end

ScreenTopology.singleDisplay = ScreenTopology.oneDisplay

---@class ScreenTopology.Rectangle
---@field x number
---@field y number
---@field width number
---@field height number

---@class ScreenTopology.Surface
---@field id string
---@field rect ScreenTopology.Rectangle
---@field safeRect ScreenTopology.Rectangle
---@field touch boolean
---@field role "world"|"auxiliary"
---@field occupiedRegions ScreenTopology.Rectangle[]

---@class ScreenTopology.SurfaceSpec
---@field id string
---@field rect ScreenTopology.Rectangle
---@field safeRect? ScreenTopology.Rectangle
---@field touch boolean
---@field role "world"|"auxiliary"
---@field occupiedRegions? ScreenTopology.Rectangle[]

return ScreenTopology
