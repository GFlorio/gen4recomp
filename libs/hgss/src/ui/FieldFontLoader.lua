-- Loads the compiled dialogue font definition for runtime text layout. This
-- deliberately owns no atlas or graphics objects; presentation loads those
-- separately when it creates the dialogue renderer. A loaded definition must
-- satisfy the v3 codec contract before presentation construction: the seven
-- color bands over a positive base-band stride, an atlas tall enough for every
-- band, a named semantic glyph mask atlas path, and the four 24x32
-- focus-indicator frame rects. A stale or malformed pre-change definition is
-- rejected here, not at individual draw calls.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldFontCache = require("libs.assets.src.field.FieldFontCache")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")

local FieldFontLoader = {}

-- Returns nil + a reason string when the definition violates the v2 codec
-- contract. No mutation.
---@param definition table<string, unknown>
---@return boolean?, string?
local function definitionValid(definition)
  local variants = definition.colorVariants
  if type(variants) ~= "table" or variants.count ~= FieldMessageText.COLOR_VARIANT_COUNT then
    return nil, "colorVariants must declare exactly " .. FieldMessageText.COLOR_VARIANT_COUNT .. " bands"
  end
  if type(variants.strideY) ~= "number" or variants.strideY <= 0 or variants.strideY % 1 ~= 0 then
    return nil, "colorVariants.strideY must be a positive integer"
  end
  local atlas = definition.atlas
  if
    type(atlas) ~= "table"
    or type(atlas.baseHeight) ~= "number"
    or atlas.baseHeight <= 0
    or atlas.baseHeight % 1 ~= 0
  then
    return nil, "atlas.baseHeight must be a positive integer"
  end
  if type(atlas.height) ~= "number" or atlas.height < atlas.baseHeight * variants.count then
    return nil, "atlas height must fit every color band"
  end
  if type(definition.maskAtlasPath) ~= "string" or definition.maskAtlasPath == "" then
    return nil, "maskAtlasPath must name the semantic glyph mask atlas"
  end
  local focus = definition.focusIndicators
  if
    type(focus) ~= "table"
    or focus.count ~= FieldMessageText.FOCUS_INDICATOR_COUNT
    or type(focus.frames) ~= "table"
  then
    return nil, "focusIndicators must declare exactly " .. FieldMessageText.FOCUS_INDICATOR_COUNT .. " frames"
  end
  for field = 0, focus.count - 1 do
    local rect = focus.frames[field]
    if
      type(rect) ~= "table"
      or rect.width ~= FieldFontCache.FOCUS_FRAME_WIDTH
      or rect.height ~= FieldFontCache.FOCUS_FRAME_HEIGHT
    then
      return nil,
        "focus frame "
          .. field
          .. " must be exactly "
          .. FieldFontCache.FOCUS_FRAME_WIDTH
          .. "x"
          .. FieldFontCache.FOCUS_FRAME_HEIGHT
    end
  end
  return true
end

---@param cacheFs CacheFs
---@param fontId integer?
---@return FieldFontDef
function FieldFontLoader.load(cacheFs, fontId)
  assert(cacheFs and cacheFs.loadLua, "FieldFontLoader requires a CacheFs-shaped object")
  fontId = fontId or 0
  local path = FieldFontCache.defPath(fontId)
  local definition = cacheFs:loadLua(path)
  if type(definition) ~= "table" or definition.schema ~= FieldFontCache.SCHEMA then
    Errors.raise(
      FieldErrors.FONT_DEF_MISSING,
      "no " .. FieldFontCache.SCHEMA .. " definition at " .. path,
      { fontId = fontId, path = path }
    )
  end
  local valid, reason = definitionValid(definition --[[@as table]])
  if not valid then
    Errors.raise(
      FieldErrors.FONT_DEF_INVALID,
      FieldFontCache.SCHEMA .. " definition at " .. path .. " is malformed: " .. reason,
      { fontId = fontId, path = path, reason = reason }
    )
  end
  return definition --[[@as FieldFontDef]]
end

return FieldFontLoader
