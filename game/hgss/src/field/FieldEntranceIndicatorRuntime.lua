-- Runtime composition for the directional entrance field effect. This keeps
-- generated-asset loading and lifecycle rebinding outside FieldRuntime's large
-- boot closure while leaving the effect state itself pure and engine-owned.

local FieldEffectAssetCache = require("libs.assets.src.field.FieldEffectAssetCache")
local FieldEntranceIndicator = require("libs.hgss.src.field.FieldEntranceIndicator")
local ModelAsset = require("libs.assets.src.model.ModelAsset")
local Contract = require("libs.assets.src.DerivedAssetContract")

local M = {}

function M.load(cacheFs)
  local index = assert(
    cacheFs:loadLua(FieldEffectAssetCache.indexPath()),
    "field-effect cache is cold -- run `scripts/buildcache.sh` first"
  )
  assert(index.schema == Contract.fieldEffects.indexSchema, "field-effect index schema is unsupported")
  local effects = {}
  for _, kind in ipairs({ "warp_entrance", "tall_grass", "very_tall_grass", "trainer_reveal", "surf_attachment" }) do
    local entry = assert(index.effects[kind], "field-effect index is missing " .. kind)
    local definition = assert(cacheFs:loadLua(entry.path), "field-effect definition is missing: " .. kind)
    ModelAsset.validate(definition.model)
    effects[kind] = definition
  end
  local model = effects.warp_entrance.model
  ModelAsset.validate(model)
  return { model = model, schema = index.schema, index = index, effects = effects }, FieldEntranceIndicator.new()
end

return M
