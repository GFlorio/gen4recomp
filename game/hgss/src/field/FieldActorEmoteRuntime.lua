-- Runtime composition for movement-emote indicator models. Mirrors
-- FieldEntranceIndicatorRuntime: keeps generated-asset loading outside
-- FieldRuntime's boot closure. There is no per-effect ticking state (unlike
-- the entrance indicator) -- the actor manager's draw record already carries
-- activeEmoteKind and the final presented world position, so the renderer reads
-- those directly every frame.

local FieldEmoteAssetCache = require("libs.assets.src.field.FieldEmoteAssetCache")

local M = {}

function M.load(cacheFs)
  local exclamation = assert(
    cacheFs:loadLua(FieldEmoteAssetCache.exclamationDescriptorPath()),
    "field emote cache is cold -- run `scripts/buildcache.sh` first"
  )
  local valid, err = FieldEmoteAssetCache.validateDescriptor(exclamation)
  if not valid then
    error(err, 0)
  end
  return { exclamation = exclamation }
end

return M
