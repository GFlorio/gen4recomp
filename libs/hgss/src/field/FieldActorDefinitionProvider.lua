-- Owns compiled actor definitions for the non-rendering field runtime. It
-- never opens an atlas or creates a graphics resource; presentation owns that
-- work through FieldActorAssetProvider.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")
local FieldActorCache = require("libs.assets.src.FieldActorCache")

---@class FieldActorDefinitionProvider: FieldActorAssets
---@field private _cacheFs CacheFs
---@field private _known table<integer, boolean>
---@field private _entries table<integer, { spriteId: integer, visual: table, references: integer }>
local FieldActorDefinitionProvider = {}
FieldActorDefinitionProvider.__index = FieldActorDefinitionProvider

---@param cacheFs CacheFs
---@return FieldActorDefinitionProvider
function FieldActorDefinitionProvider.new(cacheFs)
  assert(cacheFs, "FieldActorDefinitionProvider requires a CacheFs")
  local index = FieldActorCache.loadIndex(cacheFs)
  if type(index) ~= "table" or index.schema ~= FieldActorCache.INDEX_SCHEMA then
    Errors.raise(
      FieldErrors.FIELD_ACTOR_INDEX_UNAVAILABLE,
      "no compiled field-actor index at " .. FieldActorCache.indexPath(),
      { path = FieldActorCache.indexPath() }
    )
  end
  local known = {}
  for _, spriteId in ipairs(index.spriteIds) do
    known[spriteId] = true
  end
  return setmetatable({ _cacheFs = cacheFs, _known = known, _entries = {} }, FieldActorDefinitionProvider)
end

function FieldActorDefinitionProvider:knows(spriteId)
  return self._known[spriteId] == true
end

function FieldActorDefinitionProvider:acquire(spriteId)
  if not self:knows(spriteId) then
    Errors.raise(
      FieldErrors.FIELD_ACTOR_SPRITE_NOT_COMPILED,
      "spriteId " .. tostring(spriteId) .. " is not in the compiled actor set",
      { spriteId = spriteId }
    )
  end
  local entry = self._entries[spriteId]
  if not entry then
    local visual = self._cacheFs:loadLua(FieldActorCache.visualPath(spriteId))
    if type(visual) ~= "table" or visual.schema ~= FieldActorCache.SCHEMA then
      Errors.raise(
        FieldErrors.FIELD_ACTOR_VISUAL_UNAVAILABLE,
        "no " .. FieldActorCache.SCHEMA .. " definition for spriteId " .. spriteId,
        { spriteId = spriteId, path = FieldActorCache.visualPath(spriteId) }
      )
    end
    -- The guard above raised for a non-table, so the loaded artifact is a
    -- valid visual here; the assert narrows the loadLua `table?` for LuaLS.
    local resident = assert(visual)
    entry = { spriteId = spriteId, visual = resident, references = 0 }
    self._entries[spriteId] = entry
  end
  entry.references = entry.references + 1
  return entry
end

function FieldActorDefinitionProvider:release(spriteId)
  local entry = self._entries[spriteId]
  if not entry then
    Errors.raise(
      FieldErrors.FIELD_ACTOR_RELEASE_UNKNOWN,
      "released spriteId " .. tostring(spriteId) .. ", which is not resident",
      { spriteId = spriteId }
    )
  end
  if entry.references == 0 then
    Errors.raise(
      FieldErrors.FIELD_ACTOR_RELEASE_UNBALANCED,
      "released spriteId " .. spriteId .. " more times than it was acquired",
      { spriteId = spriteId }
    )
  end
  entry.references = entry.references - 1
  if entry.references == 0 then
    self._entries[spriteId] = nil
  end
end

function FieldActorDefinitionProvider:dispose()
  self._entries = {}
end

return FieldActorDefinitionProvider
