-- Persists a compiled field-actor bundle through the shared staged
-- publication primitive: atlases, visual definitions, provenance, and the
-- index are written into a disposable staging root, read back and validated
-- there, and only then is the completed stage published over the live actor
-- roots with the marker last. A failure at any point leaves the previous live
-- actor artifact untouched; the stage is discarded. The raw ROM dump and any
-- compiled map are never touched.

local Errors = require("libs.errors.src.Errors")
local PngWriter = require("libs.assets.src.PngWriter")
local FieldActorCache = require("libs.assets.src.FieldActorCache")
local ArtifactPublisher = require("libs.storage.src.ArtifactPublisher")

local FieldActorCacheWriter = {}

function FieldActorCacheWriter.isReady(cacheFs, marker)
  return FieldActorCache.isReady(cacheFs, marker)
end

local function persist(tx, bundle)
  local stage = tx.stage

  for _, spriteId in ipairs(bundle.index.spriteIds) do
    local atlas = bundle.atlases[spriteId]
    local visual = bundle.visuals[spriteId]
    if not atlas or not visual then
      Errors.raise(
        "FIELD_ACTOR_BUNDLE_INCOMPLETE",
        "bundle indexes spriteId " .. spriteId .. " without a visual definition and atlas",
        { spriteId = spriteId }
      )
    end
    stage:write(FieldActorCache.atlasPath(spriteId), PngWriter.encode(atlas.width, atlas.height, atlas.pixels))
    stage:writeLua(FieldActorCache.visualPath(spriteId), visual)
  end
  stage:writeLua(FieldActorCache.provenancePath(), bundle.provenance)
  stage:writeLua(FieldActorCache.indexPath(), bundle.index)

  local index = stage:loadLua(FieldActorCache.indexPath())
  if type(index) ~= "table" or index.schema ~= FieldActorCache.INDEX_SCHEMA then
    Errors.raise(
      "FIELD_ACTOR_CACHE_READBACK_FAILED",
      "actor index did not read back with schema " .. FieldActorCache.INDEX_SCHEMA,
      {}
    )
  end
  for _, spriteId in ipairs(index.spriteIds) do
    local visual = stage:loadLua(FieldActorCache.visualPath(spriteId))
    if type(visual) ~= "table" or visual.schema ~= FieldActorCache.SCHEMA then
      Errors.raise(
        "FIELD_ACTOR_CACHE_READBACK_FAILED",
        "visual definition for spriteId " .. spriteId .. " did not read back",
        { spriteId = spriteId }
      )
    end
    if not stage:exists(FieldActorCache.atlasPath(spriteId), "file") then
      Errors.raise(
        "FIELD_ACTOR_CACHE_MISSING_ATLAS",
        "atlas missing after write for spriteId " .. spriteId,
        { spriteId = spriteId }
      )
    end
  end

  stage:write(FieldActorCache.markerPath(), bundle.marker)
  tx:publish()
  return bundle.marker
end

function FieldActorCacheWriter.write(cacheFs, bundle)
  assert(cacheFs and type(bundle) == "table" and bundle.marker, "invalid actor bundle")
  local tx = ArtifactPublisher.begin(cacheFs, "field-actors", {
    FieldActorCache.assetDir(),
    FieldActorCache.dir(),
  })
  local ok, result = pcall(persist, tx, bundle)
  if ok then
    return result
  end
  tx:abort()
  error(result)
end

return FieldActorCacheWriter
