-- Runtime composition for the directional entrance field effect. This keeps
-- generated-asset loading and lifecycle rebinding outside FieldRuntime's large
-- boot closure while leaving the effect state itself pure and engine-owned.

local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local FieldEntranceIndicator = require("libs.engine.src.FieldEntranceIndicator")
local ModelAsset = require("libs.assets.src.ModelAsset")

local M = {}

function M.load(cacheFs)
  local model = assert(
    cacheFs:loadLua(FieldEffectAssetCache.modelPath()),
    "warp entrance field effect cache is cold -- run `scripts/buildcache.sh` first"
  )
  ModelAsset.validate(model)
  return { model = model }, FieldEntranceIndicator.new()
end

return M
