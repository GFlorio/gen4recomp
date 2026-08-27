-- Strict cache contract for generated field movement-emote indicator models
-- (the billboard drawn above an actor while it performs a decoded emote
-- action, such as the exclamation mark).

local Contract = require("libs.assets.src.DerivedAssetContract")
local Errors = require("libs.errors.src.Errors")
local ModelAsset = require("libs.assets.src.ModelAsset")

local FieldEmoteAssetCache = {}
FieldEmoteAssetCache.FORMAT = Contract.fieldEmotes.cacheFormat
FieldEmoteAssetCache.SCHEMA = Contract.fieldEmotes.schema
FieldEmoteAssetCache.ERROR_INVALID = "FIELD_EMOTE_DESC_INVALID"
local DIR = "data/generated/field/emotes"
local EXCLAMATION_DESCRIPTOR = DIR .. "/exclamation_model.lua"
local MARKER = DIR .. "/complete"
local ASSET_DIR = "assets/generated/field/emotes"

function FieldEmoteAssetCache.exclamationDescriptorPath()
  return EXCLAMATION_DESCRIPTOR
end
function FieldEmoteAssetCache.markerPath()
  return MARKER
end
function FieldEmoteAssetCache.geometryPath(sha1)
  return ASSET_DIR .. "/geometry/" .. sha1 .. ".g4mesh"
end
function FieldEmoteAssetCache.texturePath(sha1)
  return ASSET_DIR .. "/textures/" .. sha1 .. ".png"
end
function FieldEmoteAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldEmoteAssetCache.FORMAT, romSha1, depHash)
end

local function invalid(reason)
  return false, Errors.new(FieldEmoteAssetCache.ERROR_INVALID, "field-emote descriptor is malformed: " .. reason)
end

local function exactKeys(value, expected, label)
  for key in pairs(value) do
    if not expected[key] then
      return invalid(label .. " contains unknown key " .. tostring(key))
    end
  end
  for key in pairs(expected) do
    if value[key] == nil then
      return invalid(label .. " is missing " .. key)
    end
  end
  return true
end

local function finiteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

---@param descriptor table
---@return boolean, Errors.Error?
-- Validate the feature-local generated descriptor and delegate generic model
-- validation to ModelAsset. Returns false and a structured error for malformed
-- generated data; nested model errors retain ModelAsset's error identity.
function FieldEmoteAssetCache.validateDescriptor(descriptor)
  if type(descriptor) ~= "table" then
    return invalid("descriptor is not a table")
  end
  local keysOk, keysErr = exactKeys(descriptor, { schema = true, anchorOffset = true, model = true }, "descriptor")
  if not keysOk then
    return keysOk, keysErr
  end
  if descriptor.schema ~= FieldEmoteAssetCache.SCHEMA then
    return invalid("schema must be " .. FieldEmoteAssetCache.SCHEMA .. ", got " .. tostring(descriptor.schema))
  end
  if type(descriptor.anchorOffset) ~= "table" then
    return invalid("anchorOffset must be a table")
  end
  local anchorKeysOk, anchorKeysErr =
    exactKeys(descriptor.anchorOffset, { x = true, y = true, z = true }, "anchorOffset")
  if not anchorKeysOk then
    return anchorKeysOk, anchorKeysErr
  end
  for _, axis in ipairs({ "x", "y", "z" }) do
    if not finiteNumber(descriptor.anchorOffset[axis]) then
      return invalid("anchorOffset." .. axis .. " must be a finite number")
    end
  end
  local modelOk, modelErr = pcall(ModelAsset.validate, descriptor.model)
  if not modelOk then
    if Errors.is(modelErr) then
      return false, modelErr
    end
    error(modelErr, 0)
  end
  return true
end

function FieldEmoteAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local loaded, descriptor = pcall(cacheFs.loadLua, cacheFs, EXCLAMATION_DESCRIPTOR)
  if not loaded or type(descriptor) ~= "table" then
    return false
  end
  local valid, err = FieldEmoteAssetCache.validateDescriptor(descriptor)
  if not valid then
    return false, err
  end
  local referenced, paths = pcall(ModelAsset.referencedPaths, descriptor.model)
  if not referenced then
    return false, paths
  end
  for _, path in ipairs(paths) do
    if not cacheFs:exists(path) then
      return false
    end
  end
  return true
end

return FieldEmoteAssetCache
