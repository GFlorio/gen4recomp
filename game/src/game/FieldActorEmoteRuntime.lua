-- Runtime composition for movement-emote indicator models. Mirrors
-- FieldEntranceIndicatorRuntime: keeps generated-asset loading outside
-- FieldRuntime's boot closure. There is no per-effect ticking state (unlike
-- the entrance indicator) -- the acting actor's own draw record already
-- carries activeEmoteKind, world position, and presentation offset, so the
-- renderer reads those directly every frame.

local FieldEmoteAssetCache = require("libs.assets.src.FieldEmoteAssetCache")
local ModelAsset = require("libs.assets.src.ModelAsset")

local M = {}

function M.load(cacheFs)
  local exclamation = assert(
    cacheFs:loadLua(FieldEmoteAssetCache.exclamationModelPath()),
    "field emote cache is cold -- run `scripts/buildcache.sh` first"
  )
  ModelAsset.validate(exclamation)
  return { exclamation = exclamation }
end

return M
