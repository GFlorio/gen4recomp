-- AnimationResourceCache: the per-build-run memo of compiled animation
-- resources. HGSS's shared animation archive (a/1/0/6) is referenced by many
-- models, and every map that places them recompiles the same resources
-- (resource 1/2 = door_op/door_cl alone back 24 models). Threading one cache
-- through a build run makes each (archive, memberId, sha1) tuple decode and
-- compile once; every model descriptor embeds the same immutable clip
-- record. Compiled clips are never mutated after compile, so sharing the
-- record is safe. The cache is a plain memo keyed by a caller-composed
-- string; it never touches the ROM. Pure domain module.

local AnimationResourceCache = {}
AnimationResourceCache.__index = AnimationResourceCache

---@class AnimationResourceCache
---@field entries table<string, table>

-- A fresh, empty per-run cache.
function AnimationResourceCache.new()
  return setmetatable({ entries = {} }, AnimationResourceCache)
end

-- The compiled clip record for a key, or nil when the key is not cached.
---@param key string
---@return table?
function AnimationResourceCache:get(key)
  assert(type(key) == "string" and #key > 0, "animation resource cache key must be a non-empty string")
  return self.entries[key]
end

-- Store the compiled clip record for a key.
---@param key string
---@param clip table
function AnimationResourceCache:set(key, clip)
  assert(type(key) == "string" and #key > 0, "animation resource cache key must be a non-empty string")
  assert(type(clip) == "table", "animation resource cache stores compiled clip records")
  self.entries[key] = clip
end

return AnimationResourceCache
