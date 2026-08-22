-- Runtime composition for the directional entrance field effect. This keeps
-- generated-asset loading and lifecycle rebinding outside FieldRuntime's large
-- boot closure while leaving the effect state itself pure and engine-owned.

local FieldEffectAssetCache = require("libs.assets.src.FieldEffectAssetCache")
local FieldEntranceIndicator = require("libs.engine.src.FieldEntranceIndicator")

local M = {}

function M.load(cacheFs)
  local manifest = assert(
    cacheFs:loadLua(FieldEffectAssetCache.manifestPath()),
    "warp entrance field effect cache is cold -- run `scripts/buildcache.sh` first"
  )
  local ok, err = FieldEffectAssetCache.validateManifest(manifest)
  assert(ok, err and err.message or "warp entrance field effect manifest is invalid")
  local model =
    assert(cacheFs:loadLua(FieldEffectAssetCache.modelPath()), "warp entrance field effect model is missing")
  manifest.model = model
  return manifest, FieldEntranceIndicator.new()
end

function M.update(runtime)
  runtime.fieldEntranceIndicator:updateFixed({
    map = runtime.runtimeMap,
    player = runtime.player,
    transition = { ownsField = runtime.transition.phase == "idle" },
  })
end

function M.hide(runtime)
  runtime.fieldEntranceIndicator:updateFixed({
    map = runtime.runtimeMap,
    player = runtime.player,
    transition = { ownsField = false },
  })
end

return M
