-- Map event bindings : the manifest maps map ids and event
-- keys (object actor ids, background array indices, coordinate indices) to
-- stable public script ids. Runtime bindings never contain the ROM's one-based
-- script-index convention ; the importer resolves that during
-- binding generation. Interaction resolution order follows section 29.4: the
-- facing cell prefers an interactable object, then a matching background
-- event. The module builds the trigger descriptor of section 29.2. Pure
-- domain module: no love dependency.

local Bindings = {}

local TRIGGER_KINDS = {
  object = true,
  background = true,
  coordinate = true,
  map_init = true,
  map_enter = true,
  map_resume = true,
}

---@class ScriptBindings
---@field private _maps table
local Bindings = {}
Bindings.__index = Bindings

Bindings.SCHEMA_NAME = "g4-script-bindings-v1"

---@param manifest table
---@return table bindings
function Bindings.new(manifest)
  assert(type(manifest) == "table", "bindings manifest required")
  return setmetatable({ _maps = manifest.maps or {} }, Bindings)
end

-- Resolve the public script id for one map event, or nil when the manifest
-- does not bind it.
---@param mapId integer
---@param kind string
---@param key string|integer
---@return string|nil
function Bindings:scriptFor(mapId, kind, key)
  local map = self._maps[mapId]
  if map == nil then
    return nil
  end
  local events = map[kind .. "s"]
  if events == nil then
    return nil
  end
  local scriptId = events[key]
  if type(scriptId) ~= "string" then
    return nil
  end
  return scriptId
end

-- Build the trigger descriptor for an object intent .
---@param intent table InteractionIntent
---@param scriptId string
---@param playerFacing string
---@return table
function Bindings.objectTrigger(intent, scriptId, playerFacing)
  assert(intent.kind == "object", "object trigger requires an object intent")
  assert(intent.object ~= nil, "object intent identity required")
  return {
    kind = "object",
    mapId = intent.mapId,
    objectId = intent.object.actorId,
    scriptId = scriptId,
    selfActor = intent.object.actorId,
    playerFacing = playerFacing,
    backgroundId = nil,
    coordinateId = nil,
    sourceFieldX = intent.sourceFieldX,
    sourceFieldZ = intent.sourceFieldZ,
    targetFieldX = intent.targetFieldX,
    targetFieldZ = intent.targetFieldZ,
  }
end

-- Build the trigger descriptor for a background intent.
---@param intent table InteractionIntent
---@param scriptId string
---@param playerFacing string
---@return table
function Bindings.backgroundTrigger(intent, scriptId, playerFacing)
  assert(intent.kind == "background", "background trigger requires a background intent")
  assert(intent.background ~= nil, "background intent identity required")
  return {
    kind = "background",
    mapId = intent.mapId,
    objectId = nil,
    scriptId = scriptId,
    selfActor = nil,
    playerFacing = playerFacing,
    backgroundId = intent.background.eventIndex,
    coordinateId = nil,
    sourceFieldX = intent.sourceFieldX,
    sourceFieldZ = intent.sourceFieldZ,
    targetFieldX = intent.targetFieldX,
    targetFieldZ = intent.targetFieldZ,
  }
end

-- Resolve one interaction intent against the manifest into a trigger
-- descriptor plus the bound script id, or nil when nothing is bound (spec
-- section 29.4: object preferred, then background; coordinate and map-level
-- kinds resolve by their own keys).
---@param intent table InteractionIntent
---@param playerFacing string
---@return table|nil { trigger, scriptId }
function Bindings:resolveIntent(intent, playerFacing)
  local kind = intent.kind
  if kind == "object" then
    local scriptId = self:scriptFor(intent.mapId, "object", intent.object.actorId)
    if scriptId == nil then
      return nil
    end
    return {
      trigger = Bindings.objectTrigger(intent, scriptId, playerFacing),
      scriptId = scriptId,
    }
  elseif kind == "background" then
    local scriptId = self:scriptFor(intent.mapId, "background", intent.background.eventIndex)
    if scriptId == nil then
      return nil
    end
    return {
      trigger = Bindings.backgroundTrigger(intent, scriptId, playerFacing),
      scriptId = scriptId,
    }
  elseif TRIGGER_KINDS[kind] then
    local key
    if kind == "coordinate" then
      key = intent.coordinateIndex
    elseif kind == "map_init" or kind == "map_enter" or kind == "map_resume" then
      key = 0
    end
    local scriptId = key ~= nil and self:scriptFor(intent.mapId, kind, key) or nil
    if scriptId == nil then
      return nil
    end
    return {
      trigger = {
        kind = kind,
        mapId = intent.mapId,
        objectId = nil,
        scriptId = scriptId,
        selfActor = nil,
        playerFacing = playerFacing,
        backgroundId = nil,
        coordinateId = key,
        sourceFieldX = intent.sourceFieldX,
        sourceFieldZ = intent.sourceFieldZ,
      },
      scriptId = scriptId,
    }
  end
  return nil
end

-- All bound script ids (for diagnostics and coverage): every binding kind,
-- including map-init/enter/resume events.
---@return string[]
function Bindings:allScriptIds()
  local out, seen = {}, {}
  for _, map in pairs(self._maps) do
    for _, kind in ipairs({ "object", "background", "coordinate", "map_init", "map_enter", "map_resume" }) do
      for _, scriptId in pairs(map[kind .. "s"] or {}) do
        if type(scriptId) == "string" and not seen[scriptId] then
          seen[scriptId] = true
          out[#out + 1] = scriptId
        end
      end
    end
  end
  table.sort(out)
  return out
end

return Bindings
