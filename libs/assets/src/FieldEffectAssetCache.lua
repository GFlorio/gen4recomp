-- Strict cache contract for the normalized field-effect model and its assets.

local Contract = require("libs.assets.src.DerivedAssetContract")
local ModelAsset = require("libs.assets.src.ModelAsset")

local FieldEffectAssetCache = {}
FieldEffectAssetCache.FORMAT = Contract.fieldEffects.cacheFormat
local DIR = "data/generated/field/effects"
local INDEX = DIR .. "/index.lua"
local MARKER = DIR .. "/complete"
local ASSET_DIR = "assets/generated/field/effects"

local MARKER_PREFIX = FieldEffectAssetCache.FORMAT .. ":"

local function finiteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function validLifecycle(lifecycle, frameCount)
  if type(lifecycle) ~= "table" or type(lifecycle.mode) ~= "string" then
    return false
  end
  if lifecycle.mode == "hold_until_owner_moves" then
    return finiteNumber(lifecycle.holdFrame)
      and lifecycle.holdFrame >= 0
      and lifecycle.holdFrame == math.floor(lifecycle.holdFrame)
      and finiteNumber(frameCount)
      and lifecycle.holdFrame < frameCount
      and lifecycle.frameCount == nil
  elseif lifecycle.mode == "once" then
    return finiteNumber(lifecycle.frameCount)
      and lifecycle.frameCount >= 1
      and lifecycle.frameCount == math.floor(lifecycle.frameCount)
      and finiteNumber(frameCount)
      and lifecycle.frameCount == frameCount
      and lifecycle.holdFrame == nil
  end
  return false
end

local function validPlacement(offset)
  return type(offset) == "table" and finiteNumber(offset.x) and finiteNumber(offset.y) and finiteNumber(offset.z)
end

local function validGrassDefinition(definition)
  local model = definition.model
  local animations = type(model) == "table" and model.animations
  local clip = type(animations) == "table" and animations[1]
  local lifecycle = definition.lifecycle
  local placementOffset = definition.placementOffset
  return type(definition.lifetime) == "nil"
    and type(definition.animation) == "nil"
    and type(model) == "table"
    and model.kind == "nitro-dynamic"
    and type(animations) == "table"
    and #animations == 1
    and type(clip) == "table"
    and type(lifecycle) == "table"
    and lifecycle.mode == "hold_until_owner_moves"
    and validLifecycle(lifecycle, clip.frameCount)
    and validPlacement(placementOffset)
end

local function validTrainerRevealDefinition(definition)
  local model = definition.model
  local animations = type(model) == "table" and model.animations
  local clip = type(animations) == "table" and animations[1]
  local lifecycle = definition.lifecycle
  return type(definition.lifetime) == "nil"
    and type(definition.animation) == "nil"
    and type(definition.placementOffset) == "nil"
    and type(model) == "table"
    and model.kind == "nitro-dynamic"
    and type(animations) == "table"
    and #animations == 1
    and type(clip) == "table"
    and type(lifecycle) == "table"
    and lifecycle.mode == "once"
    and validLifecycle(lifecycle, clip.frameCount)
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
  local required = { "warp_entrance", "tall_grass", "very_tall_grass", "trainer_reveal" }
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
    if kind == "warp_entrance" and (type(definition.lifetime) ~= "number" or definition.lifetime <= 0) then
      return false
    end
    if kind == "tall_grass" or kind == "very_tall_grass" then
      if not validGrassDefinition(definition) then
        return false
      end
    elseif kind == "trainer_reveal" then
      if not validTrainerRevealDefinition(definition) then
        return false
      end
    end
  end
  return true
end

return FieldEffectAssetCache
