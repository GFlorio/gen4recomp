-- Persists a compiled field-actor bundle in a marker-last transaction: atlases
-- first, then visual definitions, provenance, and the index; only after the
-- index reads back and every artifact it names is present is the completion
-- marker written. Any failure removes the actor subtrees and re-raises, never
-- touching the raw ROM dump or any compiled map.

local Errors = require("libs.rom.src.Errors")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldActorCache = require("libs.assets.src.FieldActorCache")

local FieldActorCacheWriter = {}

function FieldActorCacheWriter.isReady(cacheFs, marker)
  return FieldActorCache.isReady(cacheFs, marker)
end

local function persist(cacheFs, bundle)
  cacheFs:remove(FieldActorCache.markerPath())

  for _, spriteId in ipairs(bundle.index.spriteIds) do
    local atlas = bundle.atlases[spriteId]
    local visual = bundle.visuals[spriteId]
    if not atlas or not visual then
      Errors.raise("FIELD_ACTOR_BUNDLE_INCOMPLETE",
        "bundle indexes spriteId " .. spriteId .. " without a visual definition and atlas",
        { spriteId = spriteId })
    end
    cacheFs:write(FieldActorCache.atlasPath(spriteId),
      PngWriter.encode(atlas.width, atlas.height, atlas.pixels))
    cacheFs:writeLua(FieldActorCache.visualPath(spriteId), visual)
  end
  cacheFs:writeLua(FieldActorCache.provenancePath(), bundle.provenance)
  cacheFs:writeLua(FieldActorCache.indexPath(), bundle.index)

  local index = cacheFs:loadLua(FieldActorCache.indexPath())
  if type(index) ~= "table" or index.schema ~= FieldActorCache.INDEX_SCHEMA then
    Errors.raise("FIELD_ACTOR_CACHE_READBACK_FAILED",
      "actor index did not read back with schema " .. FieldActorCache.INDEX_SCHEMA, {})
  end
  for _, spriteId in ipairs(index.spriteIds) do
    local visual = cacheFs:loadLua(FieldActorCache.visualPath(spriteId))
    if type(visual) ~= "table" or visual.schema ~= FieldActorCache.SCHEMA then
      Errors.raise("FIELD_ACTOR_CACHE_READBACK_FAILED",
        "visual definition for spriteId " .. spriteId .. " did not read back",
        { spriteId = spriteId })
    end
    if not cacheFs:exists(FieldActorCache.atlasPath(spriteId), "file") then
      Errors.raise("FIELD_ACTOR_CACHE_MISSING_ATLAS",
        "atlas missing after write for spriteId " .. spriteId, { spriteId = spriteId })
    end
  end

  cacheFs:write(FieldActorCache.markerPath(), bundle.marker)
  return bundle.marker
end

function FieldActorCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and type(bundle) == "table" and bundle.marker, "invalid actor bundle")
  local ok, result = pcall(persist, cacheFs, bundle)
  if ok then return result end
  pcall(function() FieldActorCache.invalidate(cacheFs) end)
  error(result)
end

return FieldActorCacheWriter
