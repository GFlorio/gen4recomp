-- The immutable per-runtime window style catalogue: the three built-in HGSS
-- styles are built once from the generated field-UI manifest, external
-- (mod) descriptors are validated, copied, and merged at construction --
-- complete records only, no inheritance language -- and resolve(id) returns
-- the stored record (consumers treat it as immutable by convention). A
-- style carries presentation information only (id, role, contentGeometry,
-- graphicRegion, per-source-type signpost geometry) -- never frame/mapGraphic
-- asset replacement ids, text colors, input, script wait behavior, result
-- values, or message sources: the renderer loads the fixed generated HGSS
-- assets itself, and no renderer consumes text colors. Signpost content
-- geometry follows the HGSS signpost window: source types 0/1 reserve a
-- seven-tile (56px) wayfinding graphic on the left of the ordinary
-- 27x4-tile window (`LoadMapSignpostFrameAndGraphic`, asm/render_window.s
-- at the pinned decomp commit), text then starts at x=72 with width 160;
-- every other source type uses the full 16,152,216,32 content rect
-- (DIALOG_BOX_* constants, src/dialog_box.c, 8px/tile). Pure domain module:
-- no love, no I/O.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class FieldWindowStyles
---@field _records table<string, table> stored final style records by id
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

-- The built-in style ids, owned here: runtime, renderers, and tests must not
-- repeat these protocol strings.
FieldWindowStyles.BUILTIN = {
  DIALOGUE = "hgss.dialogue",
  SIGNPOST = "hgss.signpost",
  TRAINER_TIP = "hgss.trainer_tip",
}

-- The semantic appearance values handwritten scripts may pass to the
-- high-level sign operations in place of a registered style id. The runtime
-- resolves them to the built-in styles at script execution; any other
-- appearance string is treated as a registered style id.
FieldWindowStyles.SEMANTIC_STYLES = {
  sign = FieldWindowStyles.BUILTIN.SIGNPOST,
  trainer_tip = FieldWindowStyles.BUILTIN.TRAINER_TIP,
}

-- Resolves a semantic appearance value to its built-in style id, or returns
-- nil when the value is a raw registered style id.
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

-- Copies one external descriptor into its stored record, so a caller can
-- never mutate the catalogue through the descriptor it passed in.
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

-- The per-source-type signpost map of one descriptor: non-negative integral
-- source-type keys, each entry keyed by its own sourceType, with optional
-- contentGeometry/graphicRegion rects.
---@param id string
---@param types any
---@return table
local function validateTypes(id, types)
  if type(types) ~= "table" then
    invalidDescriptor(id, "window style types must be a table", { types = types })
  end
  local out = {}
  for key, entry in pairs(types) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 0 then
      invalidDescriptor(id, "window style type keys must be non-negative integers", { key = key })
    end
    if type(entry) ~= "table" or entry.sourceType ~= key then
      invalidDescriptor(id, "window style type entries must be keyed by their own sourceType", { key = key })
    end
    if entry.contentGeometry ~= nil and not isRect(entry.contentGeometry) then
      invalidDescriptor(id, "window style type contentGeometry must be a rectangle", { key = key })
    end
    if entry.graphicRegion ~= nil and not isRect(entry.graphicRegion) then
      invalidDescriptor(id, "window style type graphicRegion must be a rectangle", { key = key })
    end
    out[key] = copy(entry)
  end
  return out
end

-- Validates and copies one external (mod) descriptor into its final record.
-- Complete records only: role and contentGeometry are required, and the
-- hgss.* prefix is reserved for the built-ins.
---@param descriptor table
---@return table
local function finalizeDescriptor(descriptor)
  assert(type(descriptor) == "table", "window style descriptor must be a table")
  local id = descriptor.id
  if type(id) ~= "string" or id == "" then
    invalidDescriptor(id, "window style id must be a non-empty string")
  end
  if id:sub(1, #FieldWindowStyles.RESERVED_PREFIX) == FieldWindowStyles.RESERVED_PREFIX then
    Errors.raise(
      FieldErrors.WINDOW_STYLE_RESERVED_ID,
      "window style ids under the hgss. prefix are reserved for built-ins",
      { id = id }
    )
  end
  local role = descriptor.role
  if role == nil or not FieldWindowStyles.ROLES[role] then
    invalidDescriptor(id, "unknown window style role", { role = role })
  end
  if not isRect(descriptor.contentGeometry) then
    invalidDescriptor(id, "window style contentGeometry must be a non-empty integer rectangle")
  end
  if descriptor.graphicRegion ~= nil and not isRect(descriptor.graphicRegion) then
    invalidDescriptor(id, "window style graphicRegion must be a non-empty integer rectangle")
  end
  local record = copy(descriptor)
  if record.types ~= nil then
    record.types = validateTypes(id, record.types)
  end
  return record
end

-- The immutable construction boundary: the three HGSS built-ins are built
-- from the generated field-UI manifest (the strict class the runtime already
-- validated), then every external descriptor is validated and copied in.
-- Duplicate ids (including a mod shadowing a built-in) and reserved hgss.
-- ids are composition errors.
---@param manifest table the validated FieldUiAssetCache manifest
---@param descriptors table[] external (mod) complete style descriptors
---@return FieldWindowStyles
function FieldWindowStyles.new(manifest, descriptors)
  assert(type(manifest) == "table", "FieldWindowStyles requires the generated field-UI manifest")
  local signposts = manifest.signposts
  assert(
    type(signposts) == "table" and type(signposts.frame) == "table" and type(signposts.types) == "table",
    "the field-UI manifest must carry the signposts section"
  )
  local records = {}
  local function add(id, record)
    if records[id] then
      Errors.raise(FieldErrors.WINDOW_STYLE_DUPLICATE_ID, "duplicate window style id", { id = id })
    end
    records[id] = record
  end
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
    local typeRecord = {
      sourceType = entry.sourceType,
      contentGeometry = hasGraphic and copy(GRAPHIC_TEXT) or copy(FULL_WIDTH_TEXT),
    }
    if hasGraphic then
      typeRecord.graphicRegion = copy(GRAPHIC_REGION)
    end
    types[entry.sourceType] = typeRecord
  end
  add(FieldWindowStyles.BUILTIN.DIALOGUE, {
    id = FieldWindowStyles.BUILTIN.DIALOGUE,
    role = "dialogue",
    contentGeometry = copy(FULL_WIDTH_TEXT),
  })
  add(FieldWindowStyles.BUILTIN.SIGNPOST, {
    id = FieldWindowStyles.BUILTIN.SIGNPOST,
    role = "signpost",
    contentGeometry = copy(FULL_WIDTH_TEXT),
    types = types,
  })
  add(FieldWindowStyles.BUILTIN.TRAINER_TIP, {
    id = FieldWindowStyles.BUILTIN.TRAINER_TIP,
    role = "trainer_tip",
    contentGeometry = copy(FULL_WIDTH_TEXT),
  })
  assert(type(descriptors) == "table", "FieldWindowStyles requires a descriptor list")
  for _, descriptor in ipairs(descriptors) do
    local record = finalizeDescriptor(descriptor)
    add(record.id, record)
  end
  return setmetatable({ _records = records }, FieldWindowStyles)
end

-- Returns the stored final record for a style id, or nil for an unknown id.
-- The records are immutable by convention: resolve() does not copy, so
-- callers must not mutate the returned record.
---@param id string
---@return table?
function FieldWindowStyles:resolve(id)
  assert(type(id) == "string" and id ~= "", "window style id must be a non-empty string")
  return self._records[id]
end

return FieldWindowStyles
