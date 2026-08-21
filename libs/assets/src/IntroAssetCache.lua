-- Readiness, paths, and strict validation for the generated Professor
-- Oak/profile presentation class. The manifest exposes semantic visual
-- records and native frame timing; source archive/member identities remain in
-- the producer provenance record and never cross into runtime assets.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")

local IntroAssetCache = {}

IntroAssetCache.FORMAT = Contract.intro.cacheFormat
IntroAssetCache.SCHEMA = Contract.intro.schema
IntroAssetCache.PROVENANCE_SCHEMA = Contract.intro.provenanceSchema
IntroAssetCache.MANIFEST_ERROR = "INTRO_MANIFEST_INVALID"
IntroAssetCache.PROVENANCE_ERROR = "INTRO_PROVENANCE_INVALID"

local DATA_DIR = "data/generated/intro"
local ASSET_DIR = "assets/generated/intro"

IntroAssetCache.REQUIRED_ASSETS = {
  "background",
  "oak",
  "marill",
  "gender.male",
  "gender.female",
  "gender.indicator",
  "shrink.male",
  "shrink.female",
}

local REQUIRED = {}
for _, id in ipairs(IntroAssetCache.REQUIRED_ASSETS) do
  REQUIRED[id] = true
end

function IntroAssetCache.dir()
  return DATA_DIR
end

function IntroAssetCache.assetDir()
  return ASSET_DIR
end

function IntroAssetCache.manifestPath()
  return DATA_DIR .. "/intro.lua"
end

function IntroAssetCache.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end

function IntroAssetCache.markerPath()
  return DATA_DIR .. "/complete"
end

function IntroAssetCache.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", IntroAssetCache.FORMAT, romSha1, dependencyHash)
end

local function invalid(message, context)
  return false, Errors.new(IntroAssetCache.MANIFEST_ERROR, message, context or {})
end

local function invalidProvenance(message, context)
  return false, Errors.new(IntroAssetCache.PROVENANCE_ERROR, message, context or {})
end

local function isInteger(value)
  return type(value) == "number" and value % 1 == 0
end

local function validateFrame(assetId, asset, frame, frameIndex)
  if type(frame) ~= "table" then
    return invalid("asset " .. assetId .. " frame must be a table", { asset = assetId, frame = frameIndex })
  end
  for _, field in ipairs({ "x", "y", "width", "height", "duration" }) do
    if not isInteger(frame[field]) or frame[field] < 0 then
      return invalid("asset " .. assetId .. " frame " .. field .. " must be a non-negative integer", {
        asset = assetId,
        frame = frameIndex,
        field = field,
      })
    end
  end
  if frame.width == 0 or frame.height == 0 or frame.duration == 0 then
    return invalid("asset " .. assetId .. " frame must have positive size and duration", {
      asset = assetId,
      frame = frameIndex,
    })
  end
  if frame.x + frame.width > asset.width or frame.y + frame.height > asset.height then
    return invalid("asset " .. assetId .. " frame escapes its payload", {
      asset = assetId,
      frame = frameIndex,
    })
  end
  if frame.anchor ~= nil then
    if type(frame.anchor) ~= "table" or not isInteger(frame.anchor.x) or not isInteger(frame.anchor.y) then
      return invalid("asset " .. assetId .. " frame anchor must contain integral x and y", {
        asset = assetId,
        frame = frameIndex,
      })
    end
  end
  return true
end

local function validateAsset(assetId, asset)
  if type(asset) ~= "table" then
    return invalid("asset " .. assetId .. " must be a table", { asset = assetId })
  end
  if type(asset.image) ~= "string" or asset.image == "" then
    return invalid("asset " .. assetId .. " must name an image path", { asset = assetId })
  end
  if not isInteger(asset.width) or asset.width < 1 or not isInteger(asset.height) or asset.height < 1 then
    return invalid("asset " .. assetId .. " needs positive integral dimensions", { asset = assetId })
  end
  if asset.filter ~= "nearest" then
    return invalid("asset " .. assetId .. " must use nearest filtering", { asset = assetId })
  end
  for key in pairs(asset) do
    if key ~= "image" and key ~= "width" and key ~= "height" and key ~= "frames" and key ~= "filter" then
      return invalid("asset " .. assetId .. " has an unknown field " .. tostring(key), { asset = assetId })
    end
  end
  for _, forbidden in ipairs({ "narcId", "memberId", "archive", "sourceMember" }) do
    if asset[forbidden] ~= nil then
      return invalid("asset " .. assetId .. " exposes source identity", { asset = assetId, field = forbidden })
    end
  end
  if type(asset.frames) ~= "table" or #asset.frames == 0 then
    return invalid("asset " .. assetId .. " needs at least one frame", { asset = assetId })
  end
  for frameIndex = 1, #asset.frames do
    local ok, err = validateFrame(assetId, asset, asset.frames[frameIndex], frameIndex)
    if not ok then
      return false, err
    end
  end
  for key in pairs(asset.frames) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > #asset.frames then
      return invalid("asset " .. assetId .. " frames must be a dense array", { asset = assetId })
    end
  end
  return true
end

---@param manifest table
---@return boolean, Errors.Error?
function IntroAssetCache.validateManifest(manifest)
  if type(manifest) ~= "table" then
    return invalid("manifest is not a table")
  end
  if manifest.schema ~= IntroAssetCache.SCHEMA then
    return invalid("manifest schema mismatch", { schema = manifest.schema, expected = IntroAssetCache.SCHEMA })
  end
  local reference = manifest.reference
  if
    type(reference) ~= "table"
    or reference.width ~= 256
    or reference.height ~= 192
    or reference.filter ~= "nearest"
  then
    return invalid("manifest reference must be the native 256x192 nearest surface")
  end
  if type(manifest.assets) ~= "table" then
    return invalid("manifest assets must be a table")
  end
  for _, assetId in ipairs(IntroAssetCache.REQUIRED_ASSETS) do
    if not manifest.assets[assetId] then
      return invalid("manifest is missing required asset " .. assetId, { asset = assetId })
    end
    local ok, err = validateAsset(assetId, manifest.assets[assetId])
    if not ok then
      return false, err
    end
  end
  for assetId in pairs(manifest.assets) do
    if not REQUIRED[assetId] then
      return invalid("manifest contains unknown asset " .. tostring(assetId), { asset = assetId })
    end
  end
  return true
end

---@param provenance table
---@return boolean, Errors.Error?
function IntroAssetCache.validateProvenance(provenance)
  if type(provenance) ~= "table" then
    return invalidProvenance("provenance is not a table")
  end
  if provenance.schema ~= IntroAssetCache.PROVENANCE_SCHEMA then
    return invalidProvenance("provenance schema mismatch", {
      schema = provenance.schema,
      expected = IntroAssetCache.PROVENANCE_SCHEMA,
    })
  end
  if type(provenance.source) ~= "table" then
    return invalidProvenance("provenance source must be a table")
  end
  for _, field in ipairs({ "repo", "commit" }) do
    if type(provenance.source[field]) ~= "string" or provenance.source[field] == "" then
      return invalidProvenance("provenance source " .. field .. " must be a non-empty string", { field = field })
    end
  end
  if type(provenance.source.sources) ~= "table" or #provenance.source.sources == 0 then
    return invalidProvenance("provenance source sources must be a non-empty array")
  end
  for sourceIndex, sourcePath in ipairs(provenance.source.sources) do
    if type(sourcePath) ~= "string" or sourcePath == "" then
      return invalidProvenance("provenance source path must be a non-empty string", { source = sourceIndex })
    end
  end
  if type(provenance.dependencies) ~= "table" then
    return invalidProvenance("provenance dependencies must be a table")
  end
  for dependencyIndex, dependency in ipairs(provenance.dependencies) do
    if type(dependency) ~= "table" then
      return invalidProvenance("provenance dependency must be a table", { dependency = dependencyIndex })
    end
    if type(dependency.archive) ~= "string" or dependency.archive == "" then
      return invalidProvenance("provenance dependency archive must be a non-empty string", {
        dependency = dependencyIndex,
      })
    end
    if type(dependency.memberId) ~= "number" or dependency.memberId % 1 ~= 0 or dependency.memberId < 0 then
      return invalidProvenance("provenance dependency memberId must be a non-negative integer", {
        dependency = dependencyIndex,
      })
    end
    for _, field in ipairs({ "role", "sha1" }) do
      if type(dependency[field]) ~= "string" or dependency[field] == "" then
        return invalidProvenance("provenance dependency " .. field .. " must be a non-empty string", {
          dependency = dependencyIndex,
          field = field,
        })
      end
    end
  end
  return true
end

function IntroAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(IntroAssetCache.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(IntroAssetCache.manifestPath())
  local ok = type(manifest) == "table" and IntroAssetCache.validateManifest(manifest)
  if not ok then
    return false
  end
  local provenance = cacheFs:loadLua(IntroAssetCache.provenancePath())
  local provenanceOk = type(provenance) == "table" and IntroAssetCache.validateProvenance(provenance)
  if not provenanceOk then
    return false
  end
  for _, asset in pairs(manifest.assets) do
    if not cacheFs:exists(asset.image, "file") then
      return false
    end
  end
  return true
end

return IntroAssetCache
