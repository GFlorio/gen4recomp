-- Loads the compiled dialogue font definition for runtime text layout. This
-- deliberately owns no atlas or graphics objects; presentation loads those
-- separately when it creates the dialogue renderer.

local Errors = require("libs.errors.src.Errors")
local FieldFontCache = require("libs.assets.src.FieldFontCache")

local FieldFontLoader = {}

---@param cacheFs CacheFs
---@param fontId integer?
---@return FieldFontDef
function FieldFontLoader.load(cacheFs, fontId)
  assert(cacheFs and cacheFs.loadLua, "FieldFontLoader requires a CacheFs-shaped object")
  fontId = fontId or 0
  local definition = cacheFs:loadLua(FieldFontCache.defPath(fontId))
  if type(definition) ~= "table" or definition.schema ~= FieldFontCache.SCHEMA then
    Errors.raise(
      "FONT_DEF_MISSING",
      "no " .. FieldFontCache.SCHEMA .. " definition at " .. FieldFontCache.defPath(fontId),
      { fontId = fontId, path = FieldFontCache.defPath(fontId) }
    )
  end
  return definition --[[@as FieldFontDef]]
end

return FieldFontLoader
