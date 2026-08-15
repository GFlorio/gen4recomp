-- Per-runtime window-style catalogue for field presentation: the three HGSS
-- built-in styles are built from the generated field-UI manifest at
-- construction, boot-config custom descriptors are validated and copied once,
-- and the catalogue is immutable afterwards -- resolve() returns the stored
-- record, never a copy. A style carries presentation information only (id,
-- role, contentGeometry, graphicRegion, per-source-type signpost geometry) --
-- never frame/mapGraphic asset replacement ids, text colors, input, script
-- wait behavior, result values, or message sources: the renderer loads the
-- fixed generated HGSS assets itself, and no renderer consumes text colors.
-- Custom descriptors are complete records, not inheritance deltas: there is
-- no base field and no copy-on-resolve.
-- Signpost content geometry follows the HGSS signpost window: source types
-- 0/1 reserve a seven-tile (56px) wayfinding graphic on the left of the
-- ordinary 27x4-tile window (`LoadMapSignpostFrameAndGraphic`,
-- asm/render_window.s at the pinned decomp commit), text then starts at
-- x=72 with width 160; every other source type uses the full
-- 16,152,216,32 content rect (DIALOG_BOX_* constants, src/dialog_box.c,
-- 8px/tile).

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class FieldWindowStyles
---@field _styles table<string, table> stored final records by id
local FieldWindowStyles = {}
FieldWindowStyles.__index = FieldWindowStyles

-- The three style roles mods may reference.
FieldWindowStyles.ROLES = {
  dialogue = true,
  signpost = true,
  trainer_tip = true,
}

-- Built-in HGSS styles own the hgss.* prefix: a mod cannot implicitly
-- replace them.
FieldWindowStyles.RESERVED_PREFIX = "hgss."

-- The built-in style ids: one constant table so runtime, renderers, and
-- scripts never repeat the raw protocol strings.
FieldWindowStyles.BUILTIN = {
  DIALOGUE = "hgss.dialogue",
  SIGNPOST = "hgss.signpost",
  TRAINER_TIP = "hgss.trainer_tip",
}

-- The semantic appearance values handwritten scripts may pass to the
-- high-level sign operations in place of a catalogued style id. The runtime
-- resolves them to the built-in styles at script execution; any other
-- appearance string is treated as a catalogued style id.
FieldWindowStyles.SEMANTIC_STYLES = {
  sign = FieldWindowStyles.BUILTIN.SIGNPOST,
  trainer_tip = FieldWindowStyles.BUILTIN.TRAINER_TIP,
}

-- Resolves a semantic appearance value to its built-in style id, or returns
-- nil when the value is a raw catalogued style id.
---@param appearance string
---@return string|nil
function FieldWindowStyles.semanticStyleId(appearance)
  return FieldWindowStyles.SEMANTIC_STYLES[appearance]
end

-- Canonical HGSS signpost content geometry: types 0/1 reserve the wayfinding
-- graphic; the per-type presence of a wayfinding map in the generated
-- manifest selects the region.
local FULL_WIDTH_TEXT = { x = 16, y = 152, width = 216, height = 32 }
local GRAPHIC_TEXT = { x = 72, y = 152, width = 160, height = 32 }
local GRAPHIC_REGION = { x = 16, y = 152, width = 56, height = 32 }

local function isRect(value)
  if type(value) ~= "table" then
    return false
  end
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    local v = value[field]
    if type(v) ~= "number" or v % 1 ~= 0 or v < 0 then
      return false
    end
  end
  return value.width > 0 and value.height > 0
end

-- Deep copy: descriptors are validated and copied once at construction so a
-- later mutation of the caller's table never reaches the catalogue. Resolved
-- records are never copied out again.
---@param value table
---@return table
local function copy(value)
  local out = {}
  for key, item in pairs(value) do
    out[key] = type(item) == "table" and copy(item) or item
  end
  return out
end

local function invalidDescriptor(id, message, extra)
  local context = { id = id }
  if extra then
    for key, value in pairs(extra) do
      context[key] = value
    end
  end
  Errors.raise(FieldErrors.WINDOW_STYLE_INVALID_DESCRIPTOR, message, context)
end

-- Builds the three built-in HGSS styles from the generated field-UI manifest:
-- hgss.dialogue and hgss.trainer_tip are thin full-width records; hgss.signpost
-- carries a per-source-type record for every type the manifest declares,
-- preserving the raw source numbers, with the wayfinding region exactly where
-- the manifest gives a type a wayfinding map. The built-ins carry presentation
-- fields only: the renderer loads the generated HGSS assets directly.
---@param self FieldWindowStyles
---@param manifest table the validated FieldUiAssetCache manifest
local function registerBuiltins(self, manifest)
  local signposts = manifest.signposts
  assert(
    type(signposts) == "table" and type(signposts.frame) == "table" and type(signposts.types) == "table",
    "the field-UI manifest must carry the signposts section"
  )
  local types = {}
  for _, entry in pairs(signposts.types) do
    assert(
      type(entry) == "table"
        and type(entry.sourceType) == "number"
        and entry.sourceType % 1 == 0
        and entry.sourceType >= 0,
      "signpost type entries must carry a non-negative integral sourceType"
    )
    local hasGraphic = entry.wayfinding ~= nil
    local text = hasGraphic and GRAPHIC_TEXT or FULL_WIDTH_TEXT
    local typeRecord = {
      sourceType = entry.sourceType,
      contentGeometry = { x = text.x, y = text.y, width = text.width, height = text.height },
    }
    if hasGraphic then
      typeRecord.graphicRegion = {
        x = GRAPHIC_REGION.x,
        y = GRAPHIC_REGION.y,
        width = GRAPHIC_REGION.width,
        height = GRAPHIC_REGION.height,
      }
    end
    types[entry.sourceType] = typeRecord
  end
  self._styles[FieldWindowStyles.BUILTIN.DIALOGUE] = {
    id = FieldWindowStyles.BUILTIN.DIALOGUE,
    role = "dialogue",
    contentGeometry = copy(FULL_WIDTH_TEXT),
  }
  self._styles[FieldWindowStyles.BUILTIN.SIGNPOST] = {
    id = FieldWindowStyles.BUILTIN.SIGNPOST,
    role = "signpost",
    contentGeometry = copy(FULL_WIDTH_TEXT),
    types = types,
  }
  self._styles[FieldWindowStyles.BUILTIN.TRAINER_TIP] = {
    id = FieldWindowStyles.BUILTIN.TRAINER_TIP,
    role = "trainer_tip",
    contentGeometry = copy(FULL_WIDTH_TEXT),
  }
end

-- Validates one boot-config custom descriptor (a complete record: a base
-- field is rejected, because mod styles never inherit) and stores a private
-- copy. The catalogue is immutable from here on.
---@param self FieldWindowStyles
---@param descriptor table
local function register(self, descriptor)
  assert(type(descriptor) == "table", "window style descriptor must be a table")
  local id = descriptor.id
  if type(id) ~= "string" or id == "" then
    invalidDescriptor(id, "window style id must be a non-empty string")
  end
  local reservedPrefix = FieldWindowStyles.RESERVED_PREFIX
  if id:sub(1, #reservedPrefix) == reservedPrefix then
    Errors.raise(
      FieldErrors.WINDOW_STYLE_RESERVED_ID,
      "window style ids under the hgss. prefix are reserved for built-ins",
      { id = id }
    )
  end
  if self._styles[id] then
    Errors.raise(FieldErrors.WINDOW_STYLE_DUPLICATE_ID, "duplicate window style id", { id = id })
  end
  if descriptor.base ~= nil then
    invalidDescriptor(id, "custom window styles are complete records and cannot name a base", {
      base = descriptor.base,
    })
  end
  local role = descriptor.role
  if not FieldWindowStyles.ROLES[role] then
    invalidDescriptor(id, "unknown window style role", { role = role })
  end
  if descriptor.contentGeometry == nil or not isRect(descriptor.contentGeometry) then
    invalidDescriptor(id, "window style contentGeometry must be a non-empty integer rectangle")
  end
  if descriptor.graphicRegion ~= nil and not isRect(descriptor.graphicRegion) then
    invalidDescriptor(id, "window style graphicRegion must be a non-empty integer rectangle")
  end
  local types = descriptor.types
  if types ~= nil then
    if type(types) ~= "table" then
      invalidDescriptor(id, "window style types must be a table")
    end
    for key, entry in pairs(types) do
      if type(key) ~= "number" or key % 1 ~= 0 or key < 0 then
        invalidDescriptor(id, "window style type keys must be non-negative integers", { key = key })
      end
      if type(entry) ~= "table" or entry.sourceType ~= key then
        invalidDescriptor(id, "window style type entries must be keyed by their own sourceType", {
          key = key,
        })
      end
      if entry.contentGeometry ~= nil and not isRect(entry.contentGeometry) then
        invalidDescriptor(id, "window style type contentGeometry must be a rectangle")
      end
      if entry.graphicRegion ~= nil and not isRect(entry.graphicRegion) then
        invalidDescriptor(id, "window style type graphicRegion must be a rectangle")
      end
    end
  end
  self._styles[id] = copy(descriptor)
end

-- Constructs the immutable catalogue: the three HGSS built-ins from the
-- generated field-UI manifest (the strict class the runtime already
-- validated), then every boot-config custom descriptor. Custom descriptors
-- are complete records -- id, role, contentGeometry, plus optional
-- graphicRegion/types -- never inheritance deltas.
---@param uiManifest table the validated FieldUiAssetCache manifest
---@param descriptors table[] boot-config custom style descriptors
---@return FieldWindowStyles
function FieldWindowStyles.new(uiManifest, descriptors)
  assert(type(uiManifest) == "table", "FieldWindowStyles requires the generated field-UI manifest")
  assert(type(descriptors) == "table", "FieldWindowStyles requires a descriptor list")
  local self = setmetatable({ _styles = {} }, FieldWindowStyles)
  registerBuiltins(self, uiManifest)
  for _, descriptor in ipairs(descriptors) do
    register(self, descriptor)
  end
  return self
end

-- Returns the stored record for a style id, or nil for an unknown id.
-- Consumers must treat the returned record as immutable.
---@param id string
---@return table?
function FieldWindowStyles:resolve(id)
  assert(type(id) == "string" and id ~= "", "window style id must be a non-empty string")
  return self._styles[id]
end

return FieldWindowStyles
