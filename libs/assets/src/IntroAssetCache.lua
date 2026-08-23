-- Strict validation for the generated semantic Professor Oak intro assets.

local Errors = require("libs.errors.src.Errors")
local Contract = require("libs.assets.src.DerivedAssetContract")

local M = {
  FORMAT = Contract.intro.cacheFormat,
  SCHEMA = Contract.intro.schema,
  PROVENANCE_SCHEMA = Contract.intro.provenanceSchema,
  MANIFEST_ERROR = "INTRO_MANIFEST_INVALID",
  PROVENANCE_ERROR = "INTRO_PROVENANCE_INVALID",
}

local DATA_DIR, ASSET_DIR = "data/generated/intro", "assets/generated/intro"
M.REQUIRED_ASSETS = { "oak", "marill", "male", "female", "shrink_male", "shrink_female", "ball_open" }
local REQUIRED = {}
for _, id in ipairs(M.REQUIRED_ASSETS) do
  REQUIRED[id] = true
end

function M.dir()
  return DATA_DIR
end
function M.assetDir()
  return ASSET_DIR
end
function M.manifestPath()
  return DATA_DIR .. "/intro.lua"
end
function M.provenancePath()
  return DATA_DIR .. "/provenance.lua"
end
function M.markerPath()
  return DATA_DIR .. "/complete"
end
function M.marker(romSha1, dependencyHash)
  return string.format("%s:%s:%s", M.FORMAT, romSha1, dependencyHash)
end

local function invalid(message, context)
  return false, Errors.new(M.MANIFEST_ERROR, message, context or {})
end

local function integer(value)
  return type(value) == "number" and value % 1 == 0
end
local function finite(value)
  return type(value) == "number" and value == value and value < math.huge and value > -math.huge
end

local function bounds(id, value)
  if type(value) ~= "table" then
    return invalid("widget " .. id .. " sourceBounds is required", { widget = id })
  end
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    if not integer(value[field]) or value[field] < 0 then
      return invalid("widget " .. id .. " sourceBounds is invalid", { widget = id })
    end
  end
  if value.width == 0 or value.height == 0 or value.x + value.width > 256 or value.y + value.height > 192 then
    return invalid("widget " .. id .. " sourceBounds escape the source reference", { widget = id })
  end
  return true
end

local function frame(id, widget, value, index)
  if type(value) ~= "table" or type(value.image) ~= "string" or value.image == "" then
    return invalid("widget " .. id .. " frame image is required", { widget = id, frame = index })
  end
  if
    not integer(value.width)
    or value.width ~= widget.width
    or not integer(value.height)
    or value.height ~= widget.height
    or not integer(value.duration)
    or value.duration <= 0
  then
    return invalid("widget " .. id .. " frame dimensions or duration are invalid", { widget = id, frame = index })
  end
  if
    value.anchor ~= nil and (type(value.anchor) ~= "table" or not finite(value.anchor.x) or not finite(value.anchor.y))
  then
    return invalid("widget " .. id .. " frame anchor is invalid", { widget = id, frame = index })
  end
  return true
end

local function widget(id, value)
  if type(value) ~= "table" or type(value.image) ~= "string" or value.image == "" then
    return invalid("widget " .. id .. " is invalid", { widget = id })
  end
  if not integer(value.width) or value.width < 1 or not integer(value.height) or value.height < 1 then
    return invalid("widget " .. id .. " dimensions are invalid", { widget = id })
  end
  if value.sampling ~= "nearest" then
    return invalid("widget " .. id .. " must use nearest sampling", { widget = id })
  end
  if
    type(value.anchor) ~= "table"
    or not finite(value.anchor.x)
    or not finite(value.anchor.y)
    or value.anchor.x < 0
    or value.anchor.x > value.width
    or value.anchor.y < 0
    or value.anchor.y > value.height
  then
    return invalid("widget " .. id .. " anchor is invalid", { widget = id })
  end
  local ok, err = bounds(id, value.sourceBounds)
  if not ok then
    return false, err
  end
  if type(value.frames) ~= "table" or #value.frames == 0 then
    return invalid("widget " .. id .. " has no frames", { widget = id })
  end
  for index = 1, #value.frames do
    local valid, frameErr = frame(id, value, value.frames[index], index)
    if not valid then
      return false, frameErr
    end
  end
  for key in pairs(value.frames) do
    if type(key) ~= "number" or key < 1 or key > #value.frames or key % 1 ~= 0 then
      return invalid("widget " .. id .. " frames are not dense", { widget = id })
    end
  end
  return true
end

function M.validateManifest(manifest)
  if type(manifest) ~= "table" or manifest.schemaVersion ~= 2 then
    return invalid("manifest schema mismatch", { expected = 2, actual = manifest and manifest.schemaVersion })
  end
  if manifest.variant ~= "heartgold" and manifest.variant ~= "soulsilver" then
    return invalid("manifest variant is unsupported", { variant = manifest.variant })
  end
  local reference = manifest.sourceReference
  if type(reference) ~= "table" or reference.width ~= 256 or reference.height ~= 192 then
    return invalid("manifest sourceReference is invalid")
  end
  local background = manifest.background
  if
    type(background) ~= "table"
    or type(background.image) ~= "string"
    or background.width ~= 1
    or background.height ~= 192
    or background.sampling ~= "linear"
  then
    return invalid("manifest background is invalid")
  end
  if type(manifest.widgets) ~= "table" then
    return invalid("manifest widgets are required")
  end
  for _, id in ipairs(M.REQUIRED_ASSETS) do
    if not manifest.widgets[id] then
      return invalid("manifest is missing widget " .. id, { widget = id })
    end
    local ok, err = widget(id, manifest.widgets[id])
    if not ok then
      return false, err
    end
  end
  for id in pairs(manifest.widgets) do
    if not REQUIRED[id] then
      return invalid("manifest contains unknown widget " .. tostring(id), { widget = id })
    end
  end
  return true
end

function M.validateProvenance(value)
  if
    type(value) ~= "table"
    or value.schema ~= M.PROVENANCE_SCHEMA
    or type(value.source) ~= "table"
    or type(value.dependencies) ~= "table"
  then
    return false, Errors.new(M.PROVENANCE_ERROR, "intro provenance is invalid")
  end
  return true
end

function M.isReady(cacheFs, expectedMarker)
  if cacheFs:read(M.markerPath()) ~= expectedMarker then
    return false
  end
  local manifest = cacheFs:loadLua(M.manifestPath())
  local ok = type(manifest) == "table" and M.validateManifest(manifest)
  if not ok then
    return false
  end
  local provenance = cacheFs:loadLua(M.provenancePath())
  local provenanceOk = type(provenance) == "table" and M.validateProvenance(provenance)
  if not provenanceOk then
    return false
  end
  if not cacheFs:exists(manifest.background.image, "file") then
    return false
  end
  for _, value in pairs(manifest.widgets) do
    if not cacheFs:exists(value.image, "file") then
      return false
    end
    for _, item in ipairs(value.frames) do
      if not cacheFs:exists(item.image, "file") then
        return false
      end
    end
  end
  return true
end

return M
