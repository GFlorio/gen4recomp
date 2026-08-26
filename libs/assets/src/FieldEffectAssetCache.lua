-- Strict cache contract for the normalized field-effect model and its assets.

local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.ModelAsset")

local FieldEffectAssetCache = {}
FieldEffectAssetCache.FORMAT = Contract.fieldEffects.cacheFormat
local DIR = "data/generated/field/effects"
local MODEL = DIR .. "/warp_entrance_model.lua"
local INDEX = DIR .. "/index.lua"
local MARKER = DIR .. "/complete"
local ASSET_DIR = "assets/generated/field/effects"

local SOURCE = {
  tall_grass = {
    renderer = 8,
    modelMembers = { 126 },
    animationArchive = "field_static_models",
    animationMembers = { 140 },
  },
  very_tall_grass = {
    renderer = 12,
    modelMembers = { 122 },
    animationArchive = "field_static_models",
    animationMembers = { 146 },
  },
}

local ANIMATION_SOURCE_TYPE = "field-effect"
local ANIMATION_SOURCE_FORMAT = "FIELD_EFFECT_PATTERN"
local MARKER_PREFIX = FieldEffectAssetCache.FORMAT .. ":"

local function sameIntegerArray(actual, expected)
  if type(actual) ~= "table" or #actual ~= #expected then
    return false
  end
  for index, value in ipairs(expected) do
    if actual[index] ~= value then
      return false
    end
  end
  return true
end

local function validSource(kind, definition)
  local expected = SOURCE[kind]
  if not expected then
    return true
  end
  local source = definition.source
  return type(source) == "table"
    and source.renderer == expected.renderer
    and sameIntegerArray(source.modelMembers, expected.modelMembers)
    and source.animationArchive == expected.animationArchive
    and sameIntegerArray(source.animationMembers, expected.animationMembers)
end

local function validGrassSemantics(definition)
  local lifecycle = definition.lifecycle
  local placementOffset = definition.placementOffset
  return type(lifecycle) == "table"
    and lifecycle.introTicks == 12
    and lifecycle.holdFrame == 12
    and lifecycle.holdUntilOwnerMoves == true
    and type(placementOffset) == "table"
    and placementOffset.x == 0
    and placementOffset.y == 0
    and placementOffset.z == 0.625
end

function FieldEffectAssetCache.modelPath()
  return MODEL
end
function FieldEffectAssetCache.indexPath()
  return INDEX
end
function FieldEffectAssetCache.definitionPath(kind)
  assert(type(kind) == "string" and kind ~= "", "field-effect kind required")
  return DIR .. "/" .. kind .. ".lua"
end
function FieldEffectAssetCache.markerPath()
  return MARKER
end
function FieldEffectAssetCache.geometryPath(sha1)
  return ASSET_DIR .. "/geometry/" .. sha1 .. ".g4mesh"
end
function FieldEffectAssetCache.texturePath(sha1)
  return ASSET_DIR .. "/textures/" .. sha1 .. ".png"
end
function FieldEffectAssetCache.marker(romSha1, depHash)
  return string.format("%s:%s:%s", FieldEffectAssetCache.FORMAT, romSha1, depHash)
end

---@param kind string
---@return table
function FieldEffectAssetCache.source(kind)
  local source = SOURCE[kind]
  assert(source, "unknown field-effect source " .. tostring(kind))
  return source
end

function FieldEffectAssetCache.isReady(cacheFs, expectedMarker)
  if type(expectedMarker) ~= "string" or expectedMarker:sub(1, #MARKER_PREFIX) ~= MARKER_PREFIX then
    return false
  end
  if cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local loaded, index = pcall(cacheFs.loadLua, cacheFs, INDEX)
  if not loaded or type(index) ~= "table" or index.schema ~= Contract.fieldEffects.indexSchema then
    return false
  end
  local required = { "warp_entrance", "tall_grass", "very_tall_grass" }
  if type(index.effects) ~= "table" then
    return false
  end
  local effectCount = 0
  for _ in pairs(index.effects) do
    effectCount = effectCount + 1
  end
  if effectCount ~= #required then
    return false
  end
  for _, kind in ipairs(required) do
    local entry = index.effects and index.effects[kind]
    local expectedKind = kind == "warp_entrance" and "model" or "animated_model"
    if
      type(entry) ~= "table"
      or entry.kind ~= expectedKind
      or entry.definition ~= kind
      or entry.path ~= FieldEffectAssetCache.definitionPath(kind)
    then
      return false
    end
    local definitionLoaded, definition = pcall(cacheFs.loadLua, cacheFs, entry.path)
    if not definitionLoaded or type(definition) ~= "table" then
      return false
    end
    local valid, err = pcall(ModelAsset.validate, definition.model)
    if not valid then
      return false, err
    end
    local referenced, paths = pcall(ModelAsset.referencedPaths, definition.model)
    if not referenced then
      return false, paths
    end
    for _, path in ipairs(paths) do
      if not cacheFs:exists(path) then
        return false
      end
    end
    if not validSource(kind, definition) then
      return false
    end
    if kind == "warp_entrance" and (type(definition.lifetime) ~= "number" or definition.lifetime <= 0) then
      return false
    end
    if kind == "tall_grass" or kind == "very_tall_grass" then
      local model = definition.model
      local source = SOURCE[kind]
      local clip = type(model) == "table" and model.animations and model.animations[1]
      local clipSource = clip and clip.source
      if
        type(definition.lifetime) ~= "nil"
        or type(definition.animation) ~= "nil"
        or type(definition.animationSourceSha1) ~= "string"
        or type(model) ~= "table"
        or model.kind ~= "nitro-dynamic"
        or type(model.animations) ~= "table"
        or #model.animations ~= 1
        or type(clipSource) ~= "table"
        or clipSource.type ~= ANIMATION_SOURCE_TYPE
        or clipSource.format ~= ANIMATION_SOURCE_FORMAT
        or clipSource.archive ~= source.animationArchive
        or clipSource.memberId ~= source.animationMembers[1]
        or clipSource.sha1 ~= definition.animationSourceSha1
        or not validGrassSemantics(definition)
      then
        return false
      end
    end
  end
  return true
end

return FieldEffectAssetCache
