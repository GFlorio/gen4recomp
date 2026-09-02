-- Readiness and paths for the derived field-actor cache. Actor visuals are one
-- of the three independently rebuildable derived classes (map geometry, actor
-- visuals, messages/font): changing the actor compiler must not disturb the
-- raw ROM dump or any compiled map. A sprite is ready only when the completion
-- marker matches exactly and every visual definition and atlas it indexes is
-- present, so a partial build never reads as complete. The build pipeline
-- never invalidates the live actor roots: any change to the ROM, compiler, or
-- manifest changes the marker and the staged writer rebuilds the class. Paths
-- are cache-relative; all IO goes through a CacheFs.

local FieldActorCache = {}

---@class FieldActorCache.Index
---@field schema string
---@field spriteIds integer[]
---@field runtime table

---@class FieldActorCache.Polygon
---@field cullMode string
---@field polygonMode string
---@field polygonId integer
---@field translucentDepthWrite boolean
---@field depthEqual boolean
---@field polygonAlpha integer
---@field lightMask integer
---@field fogEnabled boolean

---@class FieldActorCache.Geometry
---@field vertices table[]
---@field indices integer[]
---@field anchorTiles { x: number, y: number, z: number }
---@field bounds { width: number, height: number, depth: number }
---@field center number[]?

---@class FieldActorCache.AtlasGeometry : FieldActorCache.Geometry
---@field baseTransform number[]

---@class FieldActorCache.StaticPart
---@field textured boolean
---@field alphaClass string
---@field polygon FieldActorCache.Polygon
---@field geometry FieldActorCache.Geometry

---@class FieldActorCache.AtlasRender
---@field kind "atlas"
---@field image string
---@field frameWidth integer
---@field frameHeight integer
---@field frameCount integer
---@field alphaClass string
---@field polygon FieldActorCache.Polygon
---@field geometry FieldActorCache.AtlasGeometry

---@class FieldActorCache.StaticRender
---@field kind "staticModel"
---@field image string
---@field frameWidth integer
---@field frameHeight integer
---@field frameCount integer
---@field parts FieldActorCache.StaticPart[]

---@alias FieldActorCache.Render FieldActorCache.AtlasRender|FieldActorCache.StaticRender

---@class FieldActorCache.PoseSegment
---@field frameIndex integer
---@field ticks integer
---@field displayOffsetY number?

---@class FieldActorCache.Pose
---@field frames FieldActorCache.PoseSegment[]
---@field loop boolean
---@field durationTicks integer

---@class FieldActorCache.Gesture
---@field pose FieldActorCache.Pose
---@field displayOffset { x: number, y: number, z: number }

---@class FieldActorCache.Visual
---@field schema string
---@field spriteId integer
---@field render FieldActorCache.Render
---@field directions table<string, { idle: FieldActorCache.Pose, walk: FieldActorCache.Pose? }>
---@field idlePresentation { mode: "static"|"animated", cadence: integer }
---@field gestures table<string, FieldActorCache.Gesture>

local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")
local PolygonState = require("libs.assets.src.PolygonState")

FieldActorCache.FORMAT = Contract.fieldActors.cacheFormat
FieldActorCache.SCHEMA = Contract.fieldActors.schema
FieldActorCache.INDEX_SCHEMA = Contract.fieldActors.indexSchema

local DATA_DIR = "data/generated/field/actors"
local ASSET_DIR = "assets/generated/field/actors"

function FieldActorCache.dir()
  return DATA_DIR
end
function FieldActorCache.assetDir()
  return ASSET_DIR
end
function FieldActorCache.indexPath()
  return DATA_DIR .. "/index.lua"
end
function FieldActorCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function FieldActorCache.markerPath()
  return DATA_DIR .. "/complete"
end

function FieldActorCache.visualPath(spriteId)
  return string.format("%s/visuals/%04d.lua", DATA_DIR, spriteId)
end

function FieldActorCache.atlasPath(spriteId)
  return string.format("%s/%04d.png", ASSET_DIR, spriteId)
end

function FieldActorCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldActorCache.FORMAT, romSha1, depHash)
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local VALID_ALPHA_CLASSES = {
  opaque = true,
  cutout = true,
  translucent = true,
  wireframe = true,
  mixed = true,
}

local VALID_BILLBOARD_ALPHA_CLASSES = {
  opaque = true,
  cutout = true,
}

local REQUIRED_DIRECTIONS = { north = true, south = true, west = true, east = true }

local VALID_GESTURES = { nurse_bow = true, give = true, receive = true }

local function isValidPolygon(record)
  local ok, _ = pcall(PolygonState.validate, record, "field actor")
  return ok
end

local function isFiniteVector3(value)
  return type(value) == "table" and isFiniteNumber(value.x) and isFiniteNumber(value.y) and isFiniteNumber(value.z)
end

local function isValidBounds(value)
  return type(value) == "table"
    and isFiniteNumber(value.width)
    and isFiniteNumber(value.height)
    and isFiniteNumber(value.depth)
    and value.width >= 0
    and value.height >= 0
    and value.depth >= 0
end

local function isValidCenter(value)
  if value == nil then
    return true
  end
  if not Validate.isArray(value) or #value ~= 3 then
    return false
  end
  for i = 1, 3 do
    if not isFiniteNumber(value[i]) then
      return false
    end
  end
  return true
end

local function isValidVertex(vertex)
  if type(vertex) ~= "table" then
    return false
  end
  if not isFiniteNumber(vertex.x) or not isFiniteNumber(vertex.y) or not isFiniteNumber(vertex.z) then
    return false
  end
  if not isFiniteNumber(vertex.u) or not isFiniteNumber(vertex.v) then
    return false
  end
  if not isFiniteNumber(vertex.nx) or not isFiniteNumber(vertex.ny) or not isFiniteNumber(vertex.nz) then
    return false
  end
  for _, channel in ipairs({ "r", "g", "b" }) do
    local v = vertex[channel]
    if type(v) ~= "number" or v % 1 ~= 0 or v < 0 or v > 255 then
      return false
    end
  end
  if vertex.a ~= nil then
    if type(vertex.a) ~= "number" or vertex.a % 1 ~= 0 or vertex.a < 0 or vertex.a > 255 then
      return false
    end
  end
  if
    type(vertex.colorSource) ~= "number"
    or vertex.colorSource % 1 ~= 0
    or vertex.colorSource < 0
    or vertex.colorSource > 2
  then
    return false
  end
  return true
end

local function isValidGeometry(geometry, isAtlas)
  if type(geometry) ~= "table" then
    return false
  end
  if not Validate.isArray(geometry.vertices) or #geometry.vertices == 0 then
    return false
  end
  for _, vertex in ipairs(geometry.vertices) do
    if not isValidVertex(vertex) then
      return false
    end
  end
  if not Validate.isArray(geometry.indices) or #geometry.indices == 0 then
    return false
  end
  local vertexCount = #geometry.vertices
  for _, index in ipairs(geometry.indices) do
    if type(index) ~= "number" or index % 1 ~= 0 or index < 0 or index >= vertexCount then
      return false
    end
  end
  if not isFiniteVector3(geometry.anchorTiles) then
    return false
  end
  if not isValidBounds(geometry.bounds) then
    return false
  end
  if not isValidCenter(geometry.center) then
    return false
  end
  if isAtlas then
    if not Validate.isArray(geometry.baseTransform) or #geometry.baseTransform ~= 16 then
      return false
    end
    for i = 1, 16 do
      if not isFiniteNumber(geometry.baseTransform[i]) then
        return false
      end
    end
  end
  return true
end

local function isValidRender(render, spriteId)
  if type(render) ~= "table" then
    return false
  end
  if render.image ~= FieldActorCache.atlasPath(spriteId) then
    return false
  end
  if not Validate.isNonNegativeInteger(render.frameWidth) or render.frameWidth == 0 then
    return false
  end
  if not Validate.isNonNegativeInteger(render.frameHeight) or render.frameHeight == 0 then
    return false
  end
  if not Validate.isNonNegativeInteger(render.frameCount) or render.frameCount == 0 then
    return false
  end
  if render.kind == "atlas" then
    if not VALID_BILLBOARD_ALPHA_CLASSES[render.alphaClass] then
      return false
    end
    if not isValidPolygon(render.polygon) then
      return false
    end
    if not isValidGeometry(render.geometry, true) then
      return false
    end
  elseif render.kind == "staticModel" then
    if render.frameCount ~= 1 then
      return false
    end
    if not Validate.isArray(render.parts) or #render.parts == 0 then
      return false
    end
    for _, part in ipairs(render.parts) do
      if type(part) ~= "table" then
        return false
      end
      if type(part.textured) ~= "boolean" then
        return false
      end
      if not VALID_ALPHA_CLASSES[part.alphaClass] then
        return false
      end
      if not isValidPolygon(part.polygon) then
        return false
      end
      if not isValidGeometry(part.geometry, false) then
        return false
      end
    end
  else
    return false
  end
  return true
end

local function isValidPose(pose, frameCount, requireDisplayOffsetY)
  if type(pose) ~= "table" then
    return false
  end
  if type(pose.loop) ~= "boolean" then
    return false
  end
  if not Validate.isNonNegativeInteger(pose.durationTicks) or pose.durationTicks == 0 then
    return false
  end
  if not Validate.isArray(pose.frames) or #pose.frames == 0 then
    return false
  end
  local tickTotal = 0
  for _, segment in ipairs(pose.frames) do
    if type(segment) ~= "table" then
      return false
    end
    if
      not Validate.isNonNegativeInteger(segment.frameIndex)
      or segment.frameIndex == 0
      or segment.frameIndex > frameCount
    then
      return false
    end
    if not Validate.isNonNegativeInteger(segment.ticks) or segment.ticks == 0 then
      return false
    end
    if requireDisplayOffsetY and not isFiniteNumber(segment.displayOffsetY) then
      return false
    end
    tickTotal = tickTotal + segment.ticks
  end
  if tickTotal ~= pose.durationTicks then
    return false
  end
  return true
end

function FieldActorCache.isValidVisual(visual, spriteId)
  if type(visual) ~= "table" or visual.schema ~= FieldActorCache.SCHEMA then
    return false
  end
  if spriteId ~= nil and visual.spriteId ~= spriteId then
    return false
  end
  local idlePresentation = visual.idlePresentation
  if type(idlePresentation) ~= "table" then
    return false
  end
  if idlePresentation.mode ~= "static" and idlePresentation.mode ~= "animated" then
    return false
  end
  if
    type(idlePresentation.cadence) ~= "number"
    or idlePresentation.cadence % 1 ~= 0
    or (idlePresentation.mode == "static" and idlePresentation.cadence ~= 0)
    or (idlePresentation.mode == "animated" and idlePresentation.cadence ~= 1)
  then
    return false
  end
  local render = visual.render
  if not isValidRender(render, visual.spriteId) then
    return false
  end
  if type(visual.directions) ~= "table" then
    return false
  end
  local count = 0
  for key in pairs(visual.directions) do
    if not REQUIRED_DIRECTIONS[key] then
      return false
    end
    count = count + 1
  end
  if count ~= 4 then
    return false
  end
  for direction in pairs(REQUIRED_DIRECTIONS) do
    local set = visual.directions[direction]
    if type(set) ~= "table" then
      return false
    end
    if not isValidPose(set.idle, render.frameCount, true) then
      return false
    end
    if set.walk ~= nil and not isValidPose(set.walk, render.frameCount, false) then
      return false
    end
  end
  if type(visual.gestures) ~= "table" then
    return false
  end
  if render.kind == "staticModel" and next(visual.gestures) ~= nil then
    return false
  end
  for name, record in pairs(visual.gestures) do
    if not VALID_GESTURES[name] then
      return false
    end
    if type(record) ~= "table" then
      return false
    end
    if type(record.pose) ~= "table" or type(record.displayOffset) ~= "table" then
      return false
    end
    if not isValidPose(record.pose, render.frameCount, false) then
      return false
    end
    local offset = record.displayOffset
    if not isFiniteNumber(offset.x) or not isFiniteNumber(offset.y) or not isFiniteNumber(offset.z) then
      return false
    end
  end
  return true
end

-- True only if the marker is exact, the index loads with the expected schema,
-- spriteIds is the required array of sprite ids, the runtime configuration
-- block (avatars + variable-sprite policy) is present, and every indexed
-- sprite's visual definition (with the expected schema, matching identity, and
-- required normalized idle profile) and atlas is present.
function FieldActorCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldActorCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(FieldActorCache.indexPath()) ---@type table?
  if type(index) ~= "table" or index.schema ~= FieldActorCache.INDEX_SCHEMA then
    return false
  end
  if not Validate.isArray(index.spriteIds) then
    return false
  end
  if
    type(index.runtime) ~= "table"
    or not Validate.isArray(index.runtime.avatars)
    or type(index.runtime.variableSprites) ~= "table"
  then
    return false
  end
  for _, avatar in ipairs(index.runtime.avatars) do
    if
      type(avatar) ~= "table"
      or type(avatar.id) ~= "string"
      or avatar.id == ""
      or not Validate.isNonNegativeInteger(avatar.spriteId)
      or type(avatar.gender) ~= "number"
      or avatar.gender % 1 ~= 0
    then
      return false
    end
  end
  for _, spriteId in ipairs(index.spriteIds) do
    if not Validate.isNonNegativeInteger(spriteId) then
      return false
    end
    local visual = cacheFs:loadLua(FieldActorCache.visualPath(spriteId)) ---@type table?
    if not FieldActorCache.isValidVisual(visual, spriteId) then
      return false
    end
    if not cacheFs:exists(FieldActorCache.atlasPath(spriteId), "file") then
      return false
    end
  end
  return true
end

function FieldActorCache.loadIndex(cacheFs)
  return cacheFs:loadLua(FieldActorCache.indexPath())
end

return FieldActorCache
