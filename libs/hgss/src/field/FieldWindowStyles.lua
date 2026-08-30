-- Per-runtime window-style catalogue for field presentation: the HGSS
-- built-in styles are built from the generated field-UI manifest at
-- construction, and the catalogue is immutable afterwards -- resolve()
-- returns the stored record, never a copy. A style carries presentation
-- geometry only (id, contentGeometry, per-source-type signpost geometry) --
-- never frame/mapGraphic asset replacement ids, input, script wait behavior,
-- result values, or message sources: the renderer loads the fixed generated
-- HGSS assets itself. Signpost text palette colors are not geometry: they
-- come from the generated signpost type records (manifest.signposts.types[
-- sourceType].palette, keyed by manifest.signposts.textColors), resolved
-- directly by FieldSignpostRenderer, never duplicated into this catalogue.
-- The catalogue holds production-owned built-ins only; there is no external
-- descriptor registration.
-- Signpost content geometry follows the HGSS signpost window: source types
-- 0/1 reserve a seven-tile (56px) wayfinding graphic on the left of the
-- ordinary 27x4-tile window (`LoadMapSignpostFrameAndGraphic`,
-- asm/render_window.s at the pinned decomp commit), text then starts at
-- x=72 with width 160; every other source type uses the full
-- 16,152,216,32 content rect (DIALOG_BOX_* constants, src/dialog_box.c,
-- 8px/tile).

---@class FieldWindowStyles
---@field _styles table<string, table> stored final records by id
local FieldWindowStyles = {}
FieldWindowStyles.__index = FieldWindowStyles

-- The built-in style ids: one constant table so runtime, renderers, and
-- scripts never repeat the raw protocol strings.
FieldWindowStyles.BUILTIN = {
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

-- Deep copy: the stored records never alias the canonical geometry constants
-- above, and resolve() hands out the stored record, never a copy.
---@param value table
---@return table
local function copy(value)
  local out = {}
  for key, item in pairs(value) do
    out[key] = type(item) == "table" and copy(item) or item
  end
  return out
end

-- Builds the two built-in HGSS styles from the generated field-UI manifest:
-- hgss.trainer_tip is a thin full-width record; hgss.signpost carries a
-- per-source-type record for every type the manifest declares, preserving
-- the raw source numbers, with the wayfinding region exactly where the
-- manifest gives a type a wayfinding map. The built-ins carry presentation
-- fields only: the renderer loads the generated HGSS assets directly.
---@param self FieldWindowStyles
---@param manifest table the validated FieldUiAssetCache manifest
local function registerBuiltins(self, manifest)
  local signposts = manifest.signposts
  assert(
    type(signposts) == "table" and type(signposts.types) == "table",
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
  self._styles[FieldWindowStyles.BUILTIN.SIGNPOST] = {
    id = FieldWindowStyles.BUILTIN.SIGNPOST,
    contentGeometry = copy(FULL_WIDTH_TEXT),
    types = types,
  }
  self._styles[FieldWindowStyles.BUILTIN.TRAINER_TIP] = {
    id = FieldWindowStyles.BUILTIN.TRAINER_TIP,
    contentGeometry = copy(FULL_WIDTH_TEXT),
  }
end

-- Constructs the immutable catalogue from the generated field-UI manifest
-- (the strict class the runtime already validated): the two HGSS built-ins
-- only, with no external descriptor input.
---@param uiManifest table the validated FieldUiAssetCache manifest
---@return FieldWindowStyles
function FieldWindowStyles.new(uiManifest)
  assert(type(uiManifest) == "table", "FieldWindowStyles requires the generated field-UI manifest")
  local self = setmetatable({ _styles = {} }, FieldWindowStyles)
  registerBuiltins(self, uiManifest)
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
