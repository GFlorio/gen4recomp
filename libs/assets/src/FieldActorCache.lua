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

local Validate = require("libs.assets.src.Validate")
local Contract = require("libs.assets.src.DerivedAssetContract")

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

-- True only if the marker is exact, the index loads with the expected schema,
-- spriteIds is the required array of sprite ids, the runtime configuration
-- block (avatars + variable-sprite policy) is present, and every indexed
-- sprite's visual definition (with the expected schema and matching identity)
-- and atlas is present.
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
    if type(visual) ~= "table" or visual.schema ~= FieldActorCache.SCHEMA or visual.spriteId ~= spriteId then
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
