-- Readiness, paths, and invalidation for the derived field-actor cache. Actor
-- visuals are one of the three independently rebuildable derived classes (map
-- geometry, actor visuals, messages/font): changing the actor compiler must not
-- disturb the raw ROM dump or any compiled map. A sprite is ready only when the
-- completion marker matches exactly and every visual definition and atlas it
-- indexes is present, so a partial build never reads as complete. Paths are
-- cache-relative; all IO goes through a CacheFs.

local FieldActorCache = {}

FieldActorCache.FORMAT = "field-actor-cache-v1"
FieldActorCache.SCHEMA = "g4-field-actor-v1"
FieldActorCache.INDEX_SCHEMA = "g4-field-actor-index-v1"

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
-- and every indexed sprite's visual definition and atlas is present.
function FieldActorCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(FieldActorCache.markerPath()) ~= expectedMarker then
    return false
  end
  local index = cacheFs:loadLua(FieldActorCache.indexPath())
  if type(index) ~= "table" or index.schema ~= FieldActorCache.INDEX_SCHEMA then
    return false
  end
  for _, spriteId in ipairs(index.spriteIds or {}) do
    if not cacheFs:exists(FieldActorCache.visualPath(spriteId), "file") then
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

function FieldActorCache.invalidate(cacheFs)
  for _, root in ipairs({ DATA_DIR, ASSET_DIR }) do
    assert(root:find("generated", 1, true), "derived root must live under a generated subtree")
    cacheFs:removeTree(root)
  end
  return true
end

return FieldActorCache
