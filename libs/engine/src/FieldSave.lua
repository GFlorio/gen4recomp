-- Defines and restores the project-owned field session save. The one schema
-- `g4-field-save-v3` carries the player field location, the persisted avatar
-- id, the scenario id that explains initialization, the required player-data
-- bucket (the strict profile/options model, validated through the injected
-- font charmap and frame-index context), the `world` bucket
-- (project-owned serializable state: flags, variables, objects, rng), and
-- the serializable `scripts` bucket owned by ScriptSave. There is no older
-- format: a save that is not exactly this schema is rejected. The schema
-- boundary itself validates the world bucket through the authoritative
-- event-state and rng validators, so a save store cannot skip world
-- validation. Validation covers stable simulation state only; no dialogue,
-- facing override, or actor position is persisted. This is not a Nintendo
-- DS save format.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldPlayerData = require("libs.engine.src.FieldPlayerData")
local FieldTransition = require("libs.engine.src.FieldTransition")
local ScriptRng = require("libs.engine.src.script.ScriptRng")
local WarpSystem = require("libs.engine.src.WarpSystem")

local FieldSave = {}

FieldSave.SCHEMA = "g4-field-save-v3"
-- Relative to the SaveFs root (saves/<versionId>/), never the version cache.
-- The live save is the only supported schema, so the path is the semantic
-- name rather than a schema-numbered development filename.
FieldSave.PATH = "field-session.lua"

local FACING = { north = true, south = true, west = true, east = true }
local HEIGHT_EPSILON = 1e-9

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function integer(value)
  return finite(value) and value == math.floor(value)
end

-- The field-location subset of the schema. Raising variant; the public entry
-- points wrap it in pcall per the project error convention.
local function validateFieldState(record)
  if type(record.versionId) ~= "string" or record.versionId == "" then
    Errors.raise(FieldErrors.FIELD_SAVE_VERSION_INVALID, "field save version is missing", {})
  end
  if not integer(record.mapId) or record.mapId < 0 then
    Errors.raise(FieldErrors.FIELD_SAVE_MAP_INVALID, "field save map id is invalid", { mapId = record.mapId })
  end
  if not integer(record.fieldX) or not integer(record.fieldZ) then
    Errors.raise(
      FieldErrors.FIELD_SAVE_COORDINATES_INVALID,
      "field save coordinates must be finite integers",
      { fieldX = record.fieldX, fieldZ = record.fieldZ }
    )
  end
  if not finite(record.worldY) then
    Errors.raise(FieldErrors.FIELD_SAVE_HEIGHT_INVALID, "field save height must be finite", { worldY = record.worldY })
  end
  if not integer(record.surfaceId) or record.surfaceId < 0 then
    Errors.raise(
      FieldErrors.FIELD_SAVE_SURFACE_INVALID,
      "field save surface id is invalid",
      { surfaceId = record.surfaceId }
    )
  end
  if type(record.terrainDependencyHash) ~= "string" or record.terrainDependencyHash == "" then
    Errors.raise(
      FieldErrors.FIELD_SAVE_TERRAIN_DEPENDENCY_INVALID,
      "field save terrain dependency identity is missing",
      {}
    )
  end
  if not FACING[record.facing] then
    Errors.raise(FieldErrors.FIELD_SAVE_FACING_INVALID, "field save facing is invalid", { facing = record.facing })
  end
  return record
end

local function validateAvatar(record, opts)
  if type(record.avatar) ~= "string" or record.avatar == "" then
    Errors.raise(
      FieldErrors.FIELD_SAVE_AVATAR_INVALID,
      "field save avatar must be a non-empty id string",
      { avatar = record.avatar }
    )
  end
  local avatars = opts and opts.avatars
  if avatars and not avatars[record.avatar] then
    Errors.raise(
      FieldErrors.FIELD_SAVE_AVATAR_INVALID,
      "field save avatar is not one of the compiled player graphics",
      { avatar = record.avatar }
    )
  end
end

local function validateScenario(record)
  if type(record.scenario) ~= "string" or record.scenario == "" then
    Errors.raise(
      FieldErrors.FIELD_SAVE_SCENARIO_INVALID,
      "field save scenario must be an id string",
      { scenario = record.scenario }
    )
  end
end

-- The world bucket: project-owned serializable state. The save schema
-- boundary itself validates the bucket through the authoritative
-- substructure validators -- FieldEventState for the numeric flag/var maps
-- and ScriptRng for the serialized rng state -- so no caller can omit world
-- validation.
local function validateWorld(record)
  local world = record.world
  if type(world) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_WORLD_INVALID, "field save world must be a table", {})
  end
  if type(world.objects) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_WORLD_INVALID, "field save world objects must be a table", {})
  end
  local ok, err = pcall(FieldEventState.new, { flags = world.flags, vars = world.variables })
  if not ok then
    ---@cast err Errors.Error
    Errors.raise(
      FieldErrors.FIELD_SAVE_WORLD_INVALID,
      "field save world event state is invalid: " .. tostring(err),
      { cause = Errors.is(err) and err.code or nil }
    )
  end
  if not pcall(ScriptRng.restore, world.rng) then
    Errors.raise(FieldErrors.FIELD_SAVE_WORLD_INVALID, "field save world rng state is malformed", { rng = world.rng })
  end
end

-- The scripts bucket, validated by the caller's `opts.scriptsValidate`
-- (the game layer wires ScriptSave.validate for it).
local function validateScripts(record, opts)
  if type(record.scripts) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_SCRIPTS_INVALID, "field save scripts bucket is required", {})
  end
  if opts and opts.scriptsValidate then
    local err = opts.scriptsValidate(record.scripts)
    if err ~= nil then
      Errors.raise(
        FieldErrors.FIELD_SAVE_SCRIPTS_INVALID,
        "field save scripts bucket is invalid: " .. tostring(err.message),
        { cause = err.code }
      )
    end
  end
end

local function validateAuxiliaryUi(record)
  local auxiliaryUi = record.auxiliaryUi
  if type(auxiliaryUi) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_AUXILIARY_UI_INVALID, "field save auxiliary UI state must be a table", {})
  end
  if auxiliaryUi.requested ~= "shown" and auxiliaryUi.requested ~= "hidden" then
    Errors.raise(FieldErrors.FIELD_SAVE_AUXILIARY_UI_INVALID, "field save auxiliary UI request is invalid", {})
  end
  if
    auxiliaryUi.state ~= "shown"
    and auxiliaryUi.state ~= "showing"
    and auxiliaryUi.state ~= "hidden"
    and auxiliaryUi.state ~= "hiding"
  then
    Errors.raise(FieldErrors.FIELD_SAVE_AUXILIARY_UI_INVALID, "field save auxiliary UI state is invalid", {})
  end
  if (auxiliaryUi.requested == "shown") ~= (auxiliaryUi.state == "shown" or auxiliaryUi.state == "showing") then
    Errors.raise(FieldErrors.FIELD_SAVE_AUXILIARY_UI_INVALID, "field save auxiliary UI request and state disagree", {})
  end
end

-- The player-data bucket, validated through the authoritative model with the
-- caller's injected context (the generated font charmap and the imported
-- frame-index set). The bucket is required; a missing or invalid record is
-- rejected, never defaulted or upgraded.
local function validatePlayerData(record, opts)
  if type(record.playerData) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_PLAYER_DATA_INVALID, "field save player data bucket is required", {})
  end
  local context = opts and opts.playerDataContext
  if context then
    local valid, err = FieldPlayerData.validate(record.playerData, context)
    if not valid then
      ---@cast err Errors.Error
      Errors.raise(FieldErrors.FIELD_SAVE_PLAYER_DATA_INVALID, "field save player data is invalid: " .. tostring(err), {
        cause = err.code,
      })
    end
  end
end

-- Strict schema validation (raising). Used by save and restore paths.
local function validate(record, opts)
  if type(record) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_INVALID, "field save must be a table", {})
  end
  if record.schema ~= FieldSave.SCHEMA then
    Errors.raise(FieldErrors.FIELD_SAVE_SCHEMA_UNSUPPORTED, "unsupported field save schema", { schema = record.schema })
  end
  validateFieldState(record)
  validateAvatar(record, opts)
  validateScenario(record)
  validateWorld(record)
  validateScripts(record, opts)
  validateAuxiliaryUi(record)
  validatePlayerData(record, opts)
  return record
end

function FieldSave.validate(record, opts)
  local ok, result = pcall(validate, record, opts)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

-- True only when a stable tile boundary can be captured: the player idle, no
-- transition active, and no half-open modal dialogue, presented signpost
-- window, or active application (the Start Menu, an application fade, or a
-- child application).
---@param session FieldSession?
---@return boolean?
function FieldSave.canCapture(session)
  return session
    and session.player
    and session.player.motion == "idle"
    and (not session.transition or session.transition.phase == FieldTransition.PHASES.idle)
    and (not session.dialogue or not session.dialogue:isModal())
    and (not session.signpost or not session.signpost:isModal())
    and (not session.applicationHost or not session.applicationHost:isActive())
end

-- Capture the record: the identity/location fields plus the world and
-- scripts buckets, auxiliary UI state, and the player-data bucket. Every
-- bucket is required because the current runtime capture always supplies
-- it; `opts.scriptsBucket` is the ScriptSave capture output.

---@param session FieldSession
---@param opts table
---@return table record
function FieldSave.capture(session, opts)
  assert(FieldSave.canCapture(session), "field save requires an idle tile boundary")
  assert(opts and type(opts.avatarId) == "string" and opts.avatarId ~= "", "field save capture requires an avatar id")
  assert(type(opts.scenario) == "string" and opts.scenario ~= "", "field save capture requires a scenario id")
  assert(type(opts.world) == "table", "field save capture requires a world bucket")
  assert(type(opts.scriptsBucket) == "table", "field save capture requires a scripts bucket")
  assert(type(opts.auxiliaryUi) == "table", "field save capture requires auxiliary UI state")
  assert(type(opts.playerData) == "table", "field save capture requires the player-data bucket")
  local player = session.player
  local runtimeMap = session.currentMap
  assert(type(runtimeMap.terrainDependencyHash) == "string", "runtime map terrain dependency identity required")
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
    scenario = opts.scenario,
    world = opts.world,
    scripts = opts.scriptsBucket,
    auxiliaryUi = opts.auxiliaryUi,
    playerData = opts.playerData,
  }
end

local function closestSurface(runtimeMap, localX, localZ, savedY)
  local samples = {}
  for _, plate in
    ipairs(
      runtimeMap.terrain:candidatesAt(
        localX + FieldCoordinates.TILE_CENTER_OFFSET,
        localZ + FieldCoordinates.TILE_CENTER_OFFSET
      )
    )
  do
    local sample = runtimeMap.terrain:sample(
      plate.id,
      localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ + FieldCoordinates.TILE_CENTER_OFFSET
    )
    sample.distance = math.abs(sample.worldY - savedY)
    samples[#samples + 1] = sample
  end
  table.sort(samples, function(a, b)
    if a.distance ~= b.distance then
      return a.distance < b.distance
    end
    return a.surfaceId < b.surfaceId
  end)
  if #samples == 0 then
    Errors.raise(
      FieldErrors.FIELD_SAVE_SURFACE_NOT_FOUND,
      "saved coordinate has no terrain surface",
      { mapId = runtimeMap.mapId, localX = localX, localZ = localZ }
    )
  end
  if samples[2] and math.abs(samples[2].distance - samples[1].distance) <= HEIGHT_EPSILON then
    Errors.raise(
      FieldErrors.FIELD_SAVE_SURFACE_AMBIGUOUS,
      "saved height is equally close to multiple terrain surfaces",
      {
        mapId = runtimeMap.mapId,
        localX = localX,
        localZ = localZ,
        worldY = savedY,
        firstSurfaceId = samples[1].surfaceId,
        secondSurfaceId = samples[2].surfaceId,
      }
    )
  end
  return samples[1]
end

-- Strict restore of the only schema. Returns the restored location plus the
-- persisted avatar id, world and scripts buckets, auxiliary UI state, and
-- the player-data bucket, so the caller rebuilds exactly what the save
-- holds. `opts.scriptsValidate` is the domain validator wired by the game
-- layer (ScriptSave.validate for the scripts bucket); `opts.playerDataContext`
-- is the player-data validation context; the world bucket is validated by
-- this boundary itself.
local function restore(record, loader, expectedVersionId, opts)
  validate(record, opts)
  if record.versionId ~= expectedVersionId then
    Errors.raise(
      FieldErrors.FIELD_SAVE_VERSION_MISMATCH,
      "field save belongs to another imported version",
      { expected = expectedVersionId, actual = record.versionId }
    )
  end
  local runtimeMap = loader:load(record.mapId)
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, record.fieldX, record.fieldZ)
  local surface
  if
    record.terrainDependencyHash == runtimeMap.terrainDependencyHash
    and runtimeMap.terrain:contains(
      record.surfaceId,
      localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ + FieldCoordinates.TILE_CENTER_OFFSET
    )
  then
    surface = runtimeMap.terrain:sample(
      record.surfaceId,
      localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ + FieldCoordinates.TILE_CENTER_OFFSET
    )
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
    scenario = record.scenario,
    world = record.world,
    scripts = record.scripts,
    auxiliaryUi = record.auxiliaryUi,
    playerData = record.playerData,
  }
end

function FieldSave.restore(record, loader, expectedVersionId, opts)
  assert(loader and loader.load, "field save restore loader required")
  local ok, result = pcall(restore, record, loader, expectedVersionId, opts or {})
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return FieldSave
