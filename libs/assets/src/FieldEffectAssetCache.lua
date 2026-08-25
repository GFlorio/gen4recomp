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
  tall_grass = { renderer = 8, modelMembers = { 126, 127 }, animationMembers = { 140, 141, 142, 143 } },
  very_tall_grass = { renderer = 12, modelMembers = { 122 }, animationMembers = { 146 } },
}

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

local function validAnimation(kind, definition)
  local animation = definition.animation
  local source = SOURCE[kind]
  if type(animation) ~= "table" or animation.schema ~= "g4-field-effect-animation-v1" then
    return false
  end
  if not sameIntegerArray(animation.sourceMembers, source.animationMembers) then
    return false
  end
  if type(animation.frames) ~= "table" or #animation.frames ~= #source.animationMembers then
    return false
  end
  local lifetime = 0
  for index, frame in ipairs(animation.frames) do
    if
      type(frame) ~= "table"
      or frame.memberId ~= source.animationMembers[index]
      or type(frame.duration) ~= "number"
      or frame.duration < 1
      or frame.duration ~= math.floor(frame.duration)
      or type(frame.values) ~= "table"
      or #frame.values == 0
    then
      return false
    end
    lifetime = lifetime + frame.duration
  end
  return definition.lifetime == lifetime
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

function FieldEffectAssetCache.isReady(cacheFs, expectedMarker)
  if cacheFs:read(MARKER) ~= expectedMarker then
    return false
  end
  local loaded, index = pcall(cacheFs.loadLua, cacheFs, INDEX)
  if not loaded or type(index) ~= "table" or index.schema ~= Contract.fieldEffects.indexSchema then
    return false
  end
  local required = { "warp_entrance", "tall_grass", "very_tall_grass" }
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
    if type(definition.lifetime) ~= "number" or definition.lifetime <= 0 then
      return false
    end
    if kind == "tall_grass" or kind == "very_tall_grass" then
      local source = definition.source
      local expectedSource = SOURCE[kind]
      if
        type(source) ~= "table"
        or source.renderer ~= expectedSource.renderer
        or not sameIntegerArray(source.modelMembers, expectedSource.modelMembers)
        or not sameIntegerArray(source.animationMembers, expectedSource.animationMembers)
        or not validAnimation(kind, definition)
      then
        return false
      end
    end
  end
  return true
end

return FieldEffectAssetCache
