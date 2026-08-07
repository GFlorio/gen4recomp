-- Defines and restores the project-owned field session save. The schema
-- `g4-field-save-v1` carries the player field location, the persisted avatar
-- id, the numeric event flag/variable store, and the scenario id that explains
-- initialization. It is the only schema: there are no players yet and no
-- previous format exists, so a save that is not exactly this schema is
-- rejected. Validation covers stable simulation state only: no dialogue,
-- facing override, or actor position is persisted (spec section 16). This is
-- not a Nintendo DS save format.

local Errors = require("libs.rom.src.Errors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldEventState = require("libs.engine.src.FieldEventState")
local WarpSystem = require("libs.engine.src.WarpSystem")

local FieldSave = {}

FieldSave.SCHEMA = "g4-field-save-v1"
FieldSave.PATH = "save/field-session-v1.lua"

local FACING = { north = true, south = true, west = true, east = true }
local HEIGHT_EPSILON = 1e-9

local function finite(value)
  return type(value) == "number" and value == value
    and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
  return finite(value) and value == math.floor(value)
end

-- The field-location subset of the schema. Raising variant; the public entry
-- points wrap it in pcall per the project error convention.
local function validateFieldState(record)
  if type(record.versionId) ~= "string" or record.versionId == "" then
    Errors.raise("FIELD_SAVE_VERSION_INVALID", "field save version is missing", {})
  end
  if not integer(record.mapId) or record.mapId < 0 then
    Errors.raise("FIELD_SAVE_MAP_INVALID", "field save map id is invalid",
      { mapId = record.mapId })
  end
  if not integer(record.fieldX) or not integer(record.fieldZ) then
    Errors.raise("FIELD_SAVE_COORDINATES_INVALID", "field save coordinates must be finite integers",
      { fieldX = record.fieldX, fieldZ = record.fieldZ })
  end
  if not finite(record.worldY) then
    Errors.raise("FIELD_SAVE_HEIGHT_INVALID", "field save height must be finite",
      { worldY = record.worldY })
  end
  if not integer(record.surfaceId) or record.surfaceId < 0 then
    Errors.raise("FIELD_SAVE_SURFACE_INVALID", "field save surface id is invalid",
      { surfaceId = record.surfaceId })
  end
  if type(record.terrainDependencyHash) ~= "string"
    or record.terrainDependencyHash == "" then
    Errors.raise("FIELD_SAVE_TERRAIN_DEPENDENCY_INVALID",
      "field save terrain dependency identity is missing", {})
  end
  if not FACING[record.facing] then
    Errors.raise("FIELD_SAVE_FACING_INVALID", "field save facing is invalid",
      { facing = record.facing })
  end
  return record
end

local function validateAvatar(record, opts)
  if type(record.avatar) ~= "string" or record.avatar == "" then
    Errors.raise("FIELD_SAVE_AVATAR_INVALID",
      "field save avatar must be a non-empty id string", { avatar = record.avatar })
  end
  local avatars = opts and opts.avatars
  if avatars and not avatars[record.avatar] then
    Errors.raise("FIELD_SAVE_AVATAR_INVALID",
      "field save avatar is not one of the compiled player graphics",
      { avatar = record.avatar })
  end
end

local function validateScenario(record)
  if record.scenario ~= nil
    and (type(record.scenario) ~= "string" or record.scenario == "") then
    Errors.raise("FIELD_SAVE_SCENARIO_INVALID",
      "field save scenario must be an id string or absent", { scenario = record.scenario })
  end
end

-- The persisted event store is validated through FieldEventState itself so
-- flag/var id and value rules and the entry safety limit live in one place;
-- failures surface as one save-scoped error with the domain cause attached.
local function validateEvents(record)
  if record.events == nil then return end
  if type(record.events) ~= "table" then
    Errors.raise("FIELD_SAVE_EVENT_STATE_INVALID",
      "field save events must be a table", { eventsType = type(record.events) })
  end
  local ok, err = pcall(FieldEventState.new, record.events)
  if not ok then
    local thrown = err --[[@as any]]
    Errors.raise("FIELD_SAVE_EVENT_STATE_INVALID",
      "field save event state is invalid: " .. tostring(thrown),
      Errors.is(thrown) and { cause = thrown.code } or {})
  end
end

local function requireCurrentSchema(record)
  if record.schema ~= FieldSave.SCHEMA then
    Errors.raise("FIELD_SAVE_SCHEMA_NEWER",
      "unknown field save schema; newer than runtime or corrupt",
      { schema = record.schema })
  end
end

-- Strict schema validation (raising). Used by save and restore paths.
local function validate(record, opts)
  if type(record) ~= "table" then
    Errors.raise("FIELD_SAVE_INVALID", "field save must be a table", {})
  end
  requireCurrentSchema(record)
  validateFieldState(record)
  validateAvatar(record, opts)
  validateScenario(record)
  validateEvents(record)
  return record
end

function FieldSave.validate(record, opts)
  local ok, result = pcall(validate, record, opts)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

-- True only when a stable tile boundary can be captured: the player idle, no
-- transition active, and no half-open modal dialogue (spec section 16.3).

---@param session FieldSession?
---@return boolean?
function FieldSave.canCapture(session)
  return session and session.player and session.player.motion == "idle"
    and (not session.transition or session.transition.phase == "idle")
    and (not session.dialogue or not session.dialogue:isModal())
end

-- `opts.avatarId` is the id of the compiled player graphic; `opts.eventState`
-- (optional) is serialized into the record; `opts.scenario` (optional) names
-- the project-owned scenario whose seeds explain the event store.

---@param session FieldSession
---@param opts table
---@return table v1 record
function FieldSave.capture(session, opts)
  assert(FieldSave.canCapture(session), "field save requires an idle tile boundary")
  assert(opts and type(opts.avatarId) == "string" and opts.avatarId ~= "",
    "field save capture requires an avatar id")
  local player = session.player
  local runtimeMap = session.currentMap
  assert(type(runtimeMap.terrainDependencyHash) == "string",
    "runtime map terrain dependency identity required")
  local events = { flags = {}, vars = {} }
  if opts.eventState then
    assert(type(opts.eventState.serialize) == "function",
      "field save capture requires an event state with serialize")
    events = opts.eventState:serialize()
  end
  return {
    schema = FieldSave.SCHEMA,
    versionId = session.versionId,
    mapId = runtimeMap.mapId,
    fieldX = player.fieldX,
    fieldZ = player.fieldZ,
    worldY = player.worldY,
    surfaceId = player.surfaceId,
    terrainDependencyHash = runtimeMap.terrainDependencyHash,
    facing = player.facing,
    avatar = opts.avatarId,
    scenario = opts.scenario or nil,
    events = events,
  }
end

local function closestSurface(runtimeMap, localX, localZ, savedY)
  local samples = {}
  for _, plate in ipairs(runtimeMap.terrain:candidatesAt(localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET)) do
    local sample = runtimeMap.terrain:sample(plate.id, localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET)
    sample.distance = math.abs(sample.worldY - savedY)
    samples[#samples + 1] = sample
  end
  table.sort(samples, function(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    return a.surfaceId < b.surfaceId
  end)
  if #samples == 0 then
    Errors.raise("FIELD_SAVE_SURFACE_NOT_FOUND", "saved coordinate has no terrain surface",
      { mapId = runtimeMap.mapId, localX = localX, localZ = localZ })
  end
  if samples[2] and math.abs(samples[2].distance - samples[1].distance) <= HEIGHT_EPSILON then
    Errors.raise("FIELD_SAVE_SURFACE_AMBIGUOUS",
      "saved height is equally close to multiple terrain surfaces", {
        mapId = runtimeMap.mapId, localX = localX, localZ = localZ,
        worldY = savedY, firstSurfaceId = samples[1].surfaceId,
        secondSurfaceId = samples[2].surfaceId,
      })
  end
  return samples[1]
end

-- Strict restore of the only schema. Returns the restored location plus the
-- persisted avatar id, event store, and scenario id, so the caller rebuilds
-- exactly what the save holds.
local function restore(record, loader, expectedVersionId)
  validate(record)
  if record.versionId ~= expectedVersionId then
    Errors.raise("FIELD_SAVE_VERSION_MISMATCH", "field save belongs to another imported version",
      { expected = expectedVersionId, actual = record.versionId })
  end
  local runtimeMap = loader:load(record.mapId)
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, record.fieldX, record.fieldZ)
  local surface
  if record.terrainDependencyHash == runtimeMap.terrainDependencyHash
    and runtimeMap.terrain:contains(record.surfaceId, localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET) then
    surface = runtimeMap.terrain:sample(record.surfaceId, localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET)
  else
    surface = closestSurface(runtimeMap, localX, localZ, record.worldY)
  end
  local suppression
  if WarpSystem.findAt(runtimeMap, record.fieldX, record.fieldZ) then
    suppression = { mapId = runtimeMap.mapId, fieldX = record.fieldX, fieldZ = record.fieldZ }
  end
  return {
    runtimeMap = runtimeMap,
    fieldX = record.fieldX,
    fieldZ = record.fieldZ,
    worldY = surface.worldY,
    surfaceId = surface.surfaceId,
    facing = record.facing,
    suppression = suppression,
    avatar = record.avatar,
    events = record.events or { flags = {}, vars = {} },
    scenario = record.scenario,
  }
end

function FieldSave.restore(record, loader, expectedVersionId)
  assert(loader and loader.load, "field save restore loader required")
  local ok, result = pcall(restore, record, loader, expectedVersionId)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return FieldSave
