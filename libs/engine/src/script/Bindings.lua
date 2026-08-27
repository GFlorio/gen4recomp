-- Map event bindings: the generated manifest maps map ids and event
-- identities (object event ids, background/coordinate indexes) to stable
-- public script ids. Runtime bindings never contain the ROM's one-based
-- script-index convention; the importer resolves that during
-- binding generation. Interaction resolution order: the
-- facing cell prefers an interactable object, then a matching background
-- event. The module builds the trigger descriptor and validates the binding
-- manifest strictly at load: only dispatched trigger kinds may be bound, and
-- all required sections and numeric event keys must be present. Pure domain
-- module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptCache = require("libs.assets.src.ScriptCache")

local BINDINGS_MANIFEST_INVALID = "SCRIPT_BINDING_MANIFEST_INVALID"

---@class ScriptBindings
---@field private _maps table
local Bindings = {}
Bindings.__index = Bindings

Bindings.CANONICAL_INERT_SCRIPT = "runtime.inert_interaction"

Bindings.SCHEMA_NAME = ScriptCache.BINDINGS_SCHEMA

-- Validate the manifest structure strictly: the maps table is required, every
-- map carries exactly the objects, backgrounds, and coordinates sections (a
-- missing section is an error, never an implicit empty one), keys and targets
-- have the required types. Raises SCRIPT_BINDING_MANIFEST_INVALID on any
-- violation.
---@param manifest table
local function validate(manifest)
  if manifest.schema ~= Bindings.SCHEMA_NAME or type(manifest.maps) ~= "table" then
    Errors.raise(BINDINGS_MANIFEST_INVALID, "bindings manifest requires a maps table", {})
  end
  for mapId, map in pairs(manifest.maps) do
    if type(mapId) ~= "number" or math.floor(mapId) ~= mapId then
      Errors.raise(BINDINGS_MANIFEST_INVALID, "bindings map id must be an integer", { mapId = mapId })
    end
    if type(map) ~= "table" then
      Errors.raise(BINDINGS_MANIFEST_INVALID, "bindings map entry must be a table", { mapId = mapId })
    end
    if type(map.objects) ~= "table" or type(map.backgrounds) ~= "table" or type(map.coordinates) ~= "table" then
      Errors.raise(
        BINDINGS_MANIFEST_INVALID,
        "bindings map entry requires objects, backgrounds, and coordinates arrays",
        { mapId = mapId }
      )
    end
    for section, entries in pairs(map) do
      if section ~= "objects" and section ~= "backgrounds" and section ~= "coordinates" then
        Errors.raise(
          BINDINGS_MANIFEST_INVALID,
          "unknown binding section "
            .. tostring(section)
            .. ": only object, background, and coordinate triggers are dispatched",
          { mapId = mapId, section = section }
        )
      end
      if section == "objects" then
        for key, target in pairs(entries) do
          if type(key) ~= "number" or math.floor(key) ~= key or key < 0 then
            Errors.raise(
              BINDINGS_MANIFEST_INVALID,
              "object binding key must be a non-negative integer",
              { mapId = mapId, key = key }
            )
          end
          if type(target) ~= "string" then
            Errors.raise(
              BINDINGS_MANIFEST_INVALID,
              "binding target must be a string",
              { mapId = mapId, section = section, key = key }
            )
          end
        end
      elseif section == "backgrounds" or section == "coordinates" then
        for key, target in pairs(entries) do
          if type(key) ~= "number" or math.floor(key) ~= key or key < 0 then
            Errors.raise(
              BINDINGS_MANIFEST_INVALID,
              "background binding key must be a non-negative integer",
              { mapId = mapId, key = key }
            )
          end
          if type(target) ~= "string" then
            Errors.raise(
              BINDINGS_MANIFEST_INVALID,
              "binding target must be a string",
              { mapId = mapId, section = section, key = key }
            )
          end
        end
      end
    end
  end
end

---@param manifest table
---@return table bindings
function Bindings.new(manifest)
  assert(type(manifest) == "table", "bindings manifest required")
  validate(manifest)
  return setmetatable({ _maps = manifest.maps }, Bindings)
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

-- Build the trigger descriptor for an object intent.
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
    sourceFieldX = intent.sourceFieldX,
    sourceFieldZ = intent.sourceFieldZ,
    targetFieldX = intent.targetFieldX,
    targetFieldZ = intent.targetFieldZ,
  }
end

---@param intent table
---@param scriptId string
---@param playerFacing string
---@return table
function Bindings.coordinateTrigger(intent, scriptId, playerFacing)
  assert(intent.kind == "coordinate", "coordinate trigger requires a coordinate intent")
  assert(intent.coordinate ~= nil and intent.coordinateId ~= nil, "coordinate intent identity required")
  return {
    kind = "coordinate",
    mapId = intent.mapId,
    coordinateId = intent.coordinateId,
    scriptId = scriptId,
    playerFacing = playerFacing,
    sourceFieldX = intent.sourceFieldX,
    sourceFieldZ = intent.sourceFieldZ,
    targetFieldX = intent.targetFieldX,
    targetFieldZ = intent.targetFieldZ,
    objectId = nil,
    selfActor = nil,
    backgroundId = nil,
  }
end

-- Resolve one interaction intent against the manifest into a trigger
-- descriptor plus the bound script id, or nil when nothing is bound (object
-- preferred, then background; other intent kinds are not dispatched).
---@param intent table InteractionIntent
---@param playerFacing string
---@return table|nil { trigger, scriptId }
function Bindings:resolveIntent(intent, playerFacing)
  local kind = intent.kind
  local scriptId
  if intent.scriptId == 0 then
    scriptId = Bindings.CANONICAL_INERT_SCRIPT
  elseif kind == "object" then
    assert(intent.object ~= nil, "object intent identity required")
    scriptId = self:scriptFor(intent.mapId, "object", intent.object.objectEventId)
  elseif kind == "background" then
    scriptId = self:scriptFor(intent.mapId, "background", intent.background.eventIndex)
  elseif kind == "coordinate" then
    scriptId = self:scriptFor(intent.mapId, "coordinate", intent.coordinateId)
  end
  if kind == "object" then
    if scriptId == nil then
      return nil
    end
    return {
      trigger = Bindings.objectTrigger(intent, scriptId, playerFacing),
      scriptId = scriptId,
    }
  elseif kind == "background" then
    if scriptId == nil then
      return nil
    end
    return {
      trigger = Bindings.backgroundTrigger(intent, scriptId, playerFacing),
      scriptId = scriptId,
    }
  elseif kind == "coordinate" then
    if scriptId == nil then
      return nil
    end
    return {
      trigger = Bindings.coordinateTrigger(intent, scriptId, playerFacing),
      scriptId = scriptId,
    }
  end
  return nil
end

-- All bound script ids (for diagnostics and coverage).
---@return string[]
function Bindings:allScriptIds()
  local out, seen = {}, {}
  for _, map in pairs(self._maps) do
    for _, kind in ipairs({ "object", "background", "coordinate" }) do
      for _, scriptId in pairs(map[kind .. "s"]) do
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
