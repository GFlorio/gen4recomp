-- Defines and restores the project-owned field session save. It validates only
-- stable simulation state and safely reselects terrain by saved height when the
-- compiled BDHC identity changes. This is not a Nintendo DS save format.

local Errors = require("libs.rom.src.Errors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
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

local function validate(record)
  if type(record) ~= "table" then
    Errors.raise("FIELD_SAVE_INVALID", "field save must be a table", {})
  end
  if record.schema ~= FieldSave.SCHEMA then
    Errors.raise("FIELD_SAVE_SCHEMA", "unsupported field save schema",
      { schema = record.schema })
  end
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

function FieldSave.validate(record)
  local ok, result = pcall(validate, record)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

-- True only when a stable tile boundary can be captured: the player idle, no
-- transition active, and no half-open modal dialogue (spec section 16.3).

---@param session FieldSession?
---@return boolean
function FieldSave.canCapture(session)
  return session and session.player and session.player.motion == "idle"
    and (not session.transition or session.transition.phase == "idle")
    and (not session.dialogue or not session.dialogue:isModal())
end

function FieldSave.capture(session)
  assert(FieldSave.canCapture(session), "field save requires an idle tile boundary")
  local player = session.player
  local runtimeMap = session.currentMap
  assert(type(runtimeMap.terrainDependencyHash) == "string",
    "runtime map terrain dependency identity required")
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
  }
end

local function closestSurface(runtimeMap, localX, localZ, savedY)
  local samples = {}
  for _, plate in ipairs(runtimeMap.terrain:candidatesAt(localX + 0.5, localZ + 0.5)) do
    local sample = runtimeMap.terrain:sample(plate.id, localX + 0.5, localZ + 0.5)
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
    and runtimeMap.terrain:contains(record.surfaceId, localX + 0.5, localZ + 0.5) then
    surface = runtimeMap.terrain:sample(record.surfaceId, localX + 0.5, localZ + 0.5)
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
