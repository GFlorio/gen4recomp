-- Per-runtime window style catalogue: built-in HGSS styles are loaded from
-- the generated field-UI manifest and sealed before
-- scripts/applications run; mods register derived styles against them. A
-- style carries presentation information only (id, base, role,
-- contentGeometry, graphicRegion, per-source-type signpost geometry) --
-- never frame/mapGraphic asset replacement ids, text colors, input, script
-- wait behavior, result values, or message sources: the renderer loads the
-- fixed generated HGSS assets itself, and no renderer consumes text colors.
-- Signpost content geometry follows the HGSS signpost window: source types
-- 0/1 reserve a seven-tile (56px) wayfinding graphic on the left of the
-- ordinary 27x4-tile window (`LoadMapSignpostFrameAndGraphic`,
-- asm/render_window.s at the pinned decomp commit), text then starts at
-- x=72 with width 160; every other source type uses the full
-- 16,152,216,32 content rect (DIALOG_BOX_* constants, src/dialog_box.c,
-- 8px/tile).

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class FieldWindowStyleRegistry
---@field sealed boolean true once inheritance has been resolved
---@field _descriptors table<string, table> stored (validated) descriptors by id
---@field _order string[] registration order
---@field _resolved table<string, table>? flat records after seal
local FieldWindowStyleRegistry = {}
FieldWindowStyleRegistry.__index = FieldWindowStyleRegistry

-- The three style roles mods may reference or derive.
FieldWindowStyleRegistry.ROLES = {
  dialogue = true,
  signpost = true,
  trainer_tip = true,
}

-- Built-in HGSS styles own the hgss.* prefix: a mod cannot implicitly
-- replace them.
FieldWindowStyleRegistry.RESERVED_PREFIX = "hgss."

-- The semantic appearance values handwritten scripts may pass to the
-- high-level sign operations in place of a registered style id. The
-- runtime resolves them to the built-in styles at script execution; any
-- other appearance string is treated as a registered style id.
FieldWindowStyleRegistry.SEMANTIC_STYLES = {
  sign = "hgss.signpost",
  trainer_tip = "hgss.trainer_tip",
}

-- Resolves a semantic appearance value to its built-in style id, or returns
-- nil when the value is a raw registered style id.
---@param appearance string
---@return string|nil
function FieldWindowStyleRegistry.semanticStyleId(appearance)
  return FieldWindowStyleRegistry.SEMANTIC_STYLES[appearance]
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

-- Deep copy without freezing; used for descriptor storage, inheritance
-- resolution, and every resolve() result, so a caller can never mutate the
-- sealed catalogue through a returned record.
---@param value table
---@return table
local function copy(value)
  local out = {}
  for key, item in pairs(value) do
    out[key] = type(item) == "table" and copy(item) or item
  end
  return out
end

-- The fields a derived descriptor may overlay onto its base's flat record;
-- `id` and `base` are handled separately.
local OVERLAY_FIELDS = { "role", "contentGeometry", "graphicRegion", "types" }

local function overlay(flat, descriptor)
  for _, field in ipairs(OVERLAY_FIELDS) do
    local value = descriptor[field]
    if value ~= nil then
      flat[field] = type(value) == "table" and copy(value) or value
    end
  end
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

---@return FieldWindowStyleRegistry
function FieldWindowStyleRegistry.new()
  return setmetatable({
    _descriptors = {},
    _order = {},
    _resolved = nil,
    sealed = false,
  }, FieldWindowStyleRegistry)
end

-- Validates the descriptor's own fields and stores a private copy. A base
-- may name any registered or future id; base existence and cycles resolve at
-- seal. The hgss.* prefix is reserved for built-ins; the builtin loader is
-- the only path that may register under it.
---@param descriptor table
---@param allowReserved boolean?
function FieldWindowStyleRegistry:_storeDescriptor(descriptor, allowReserved)
  if self._resolved then
    Errors.raise(FieldErrors.WINDOW_STYLE_ALREADY_SEALED, "cannot register a window style after seal", {})
  end
  assert(type(descriptor) == "table", "window style descriptor must be a table")
  local id = descriptor.id
  if type(id) ~= "string" or id == "" then
    invalidDescriptor(id, "window style id must be a non-empty string")
  end
  local reservedPrefix = FieldWindowStyleRegistry.RESERVED_PREFIX
  if not allowReserved and id:sub(1, #reservedPrefix) == reservedPrefix then
    Errors.raise(
      FieldErrors.WINDOW_STYLE_RESERVED_ID,
      "window style ids under the hgss. prefix are reserved for built-ins",
      {
        id = id,
      }
    )
  end
  if self._descriptors[id] then
    Errors.raise(FieldErrors.WINDOW_STYLE_DUPLICATE_ID, "duplicate window style id", { id = id })
  end
  local base = descriptor.base
  if base ~= nil and (type(base) ~= "string" or base == "") then
    invalidDescriptor(id, "window style base must be a non-empty string", { base = base })
  end
  local role = descriptor.role
  if role ~= nil and not FieldWindowStyleRegistry.ROLES[role] then
    invalidDescriptor(id, "unknown window style role", { role = role })
  end
  if base == nil and (role == nil or descriptor.contentGeometry == nil) then
    invalidDescriptor(id, "a base-less window style requires role and contentGeometry")
  end
  if descriptor.contentGeometry ~= nil and not isRect(descriptor.contentGeometry) then
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
  self._descriptors[id] = copy(descriptor)
  self._order[#self._order + 1] = id
end

-- Public registration for mods: full descriptors (role/contentGeometry
-- required) or derived descriptors (base required, everything else optional
-- and inherited from the base at seal).
---@param descriptor table
function FieldWindowStyleRegistry:register(descriptor)
  self:_storeDescriptor(descriptor, false)
end

-- Registers the three built-in HGSS styles from the generated field-UI
-- manifest (the strict class the runtime already validated): hgss.dialogue
-- and hgss.trainer_tip are thin full-width records; hgss.signpost carries a
-- per-source-type record for every type the manifest declares, preserving
-- the raw source numbers, with the wayfinding region exactly where the
-- manifest gives a type a wayfinding map. The built-ins carry presentation
-- fields only: the renderer loads the generated HGSS assets directly.
---@param manifest table the validated FieldUiAssetCache manifest
function FieldWindowStyleRegistry:registerBuiltins(manifest)
  assert(type(manifest) == "table", "registerBuiltins requires the generated field-UI manifest")
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
  self:_storeDescriptor({
    id = "hgss.dialogue",
    role = "dialogue",
    contentGeometry = FULL_WIDTH_TEXT,
  }, true)
  self:_storeDescriptor({
    id = "hgss.signpost",
    role = "signpost",
    contentGeometry = FULL_WIDTH_TEXT,
    types = types,
  }, true)
  self:_storeDescriptor({
    id = "hgss.trainer_tip",
    role = "trainer_tip",
    contentGeometry = FULL_WIDTH_TEXT,
  }, true)
end

-- Resolves inheritance once, in registration order, into immutable flat
-- records. A base must resolve before its derived styles; cycles and unknown
-- bases are composition errors naming both ids.
function FieldWindowStyleRegistry:seal()
  if self._resolved then
    Errors.raise(FieldErrors.WINDOW_STYLE_ALREADY_SEALED, "the window style registry is already sealed", {})
  end
  local resolved = {}
  local resolving = {}
  local function resolve(id)
    local record = resolved[id]
    if record then
      return record
    end
    if resolving[id] then
      Errors.raise(FieldErrors.WINDOW_STYLE_BASE_CYCLE, "window style base cycle", { id = id })
    end
    local descriptor = assert(self._descriptors[id])
    if descriptor.base and not self._descriptors[descriptor.base] then
      Errors.raise(FieldErrors.WINDOW_STYLE_UNKNOWN_BASE, "window style base does not exist", {
        id = id,
        base = descriptor.base,
      })
    end
    resolving[id] = true
    local flat
    if descriptor.base then
      flat = copy(resolve(descriptor.base))
      overlay(flat, descriptor)
    else
      flat = copy(descriptor)
    end
    -- A resolved record's identity is its own: a derived style must never
    -- report the base style's id, and resolved records are flat.
    flat.id = id
    flat.base = nil
    resolving[id] = nil
    resolved[id] = flat
    return resolved[id]
  end
  for _, id in ipairs(self._order) do
    resolve(id)
  end
  self._resolved = resolved
  self.sealed = true
end

-- Returns a deep copy of the sealed flat record for a style id, or nil for
-- an unknown id (the nil contract is pinned by the unit tests; the
-- annotation is kept non-optional so consumers of the sealed registry read
-- field access as plain lookup). The registry must be sealed first;
-- resolving before seal is a programming error. Copies keep the sealed
-- catalogue immutable: callers that resolve per frame (like the renderer)
-- cache the copy themselves.
---@param id string
---@return table
function FieldWindowStyleRegistry:resolve(id)
  assert(type(id) == "string" and id ~= "", "window style id must be a non-empty string")
  if not self._resolved then
    Errors.raise(FieldErrors.WINDOW_STYLE_NOT_SEALED, "the window style registry is not sealed", {})
  end
  local record = self._resolved[id]
  if record then
    return copy(record)
  end
  return self._resolved[id]
end

return FieldWindowStyleRegistry
