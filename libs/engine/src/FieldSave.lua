-- Defines and restores the project-owned field session save. The one schema
-- `g4-field-save-v4` carries the player field location, the persisted avatar
-- id, the required player-data
-- bucket (the strict profile/options model, validated through the injected
-- font charmap and frame-index context), the `world` bucket
-- (project-owned serializable state: flags, variables, objects, rng, and
-- the persisted field-music override), and the serializable `scripts` bucket
-- owned by ScriptSave. There is no older format: a save that is not exactly
-- this schema is rejected. The schema boundary itself validates the world
-- bucket through the authoritative event-state and rng validators, so a save
-- store cannot skip world validation. Validation covers stable simulation
-- state only; no dialogue, facing override, or actor position is persisted.
-- Validation also canonicalizes the player-data bucket through the model, and
-- the validated record and restore keep that canonical copy: unknown bucket
-- keys are discarded (never rejected), and the deserialized input table never
-- becomes the runtime record. This is not a Nintendo DS save format.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldPlayerData = require("libs.engine.src.FieldPlayerData")
local FieldTransition = require("libs.engine.src.FieldTransition")
local ScriptRng = require("libs.engine.src.script.ScriptRng")
local WarpSystem = require("libs.engine.src.WarpSystem")

local FieldSave = {}

---@class FieldSave.Record
---@field schema string
---@field versionId string
---@field mapId integer
---@field fieldX integer
---@field fieldZ integer
---@field worldY number
---@field surfaceId integer
---@field terrainDependencyHash string
---@field facing string
---@field avatar string
---@field world table
---@field scripts table
---@field auxiliaryUi table
---@field playerData table

---@class FieldSave.CaptureOptions
---@field avatarId string
---@field world table
---@field scriptsBucket table
---@field auxiliaryUi table
---@field playerData table

---@class FieldSave.Player
---@field fieldX number
---@field fieldZ number
---@field worldY number
---@field surfaceId integer
---@field facing string

---@class FieldSave.RuntimeMap : RuntimeFieldMap
---@field mapId integer
---@field terrainDependencyHash string
---@field terrain TerrainSurface
---@field coordinateOrigin { x: number, z: number }
---@field collision table

---@class FieldSave.Surface
---@field worldY number
---@field surfaceId integer
---@field distance number?

---@class FieldSave.CaptureMap
---@field mapId integer
---@field terrainDependencyHash string

---@class FieldSave.PlayerState
---@field motion "idle"|"walking"|"transition"
---@field fieldX integer
---@field fieldZ integer
---@field worldY number
---@field surfaceId integer
---@field facing FieldDirection

---@class FieldSave.Session
---@field versionId string
---@field currentMap FieldSave.CaptureMap
---@field player FieldSave.PlayerState
---@field transition { phase: string }?
---@field dialogue { isModal: fun(self: table): boolean }?
---@field signpost { isModal: fun(self: table): boolean }?
---@field applicationHost { isActive: fun(self: table): boolean }?

FieldSave.SCHEMA = "g4-field-save-v4"
-- Relative to the SaveFs root (saves/<versionId>/), never the version cache.
-- The live save is the only supported schema, so the path is the semantic
-- name rather than a schema-numbered development filename.
FieldSave.PATH = "field-session.lua"

local FACING = { north = true, south = true, west = true, east = true }
local HEIGHT_EPSILON = 1e-9

---@param value number
---@return boolean
local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

---@param value number
---@return boolean
local function integer(value)
  return finite(value) and value == math.floor(value)
end

-- The field-location subset of the schema. Raising variant; the public entry
-- points wrap it in pcall per the project error convention.
---@param record table
---@return table
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

---@param record table
---@param opts table?
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

-- The world bucket: project-owned serializable state. The save schema
-- boundary itself validates the bucket through the authoritative
-- substructure validators -- FieldEventState for the numeric flag/var maps
-- and ScriptRng for the serialized rng state -- so no caller can omit world
-- validation.
---@param record table
local function validateWorld(record)
  local world = record.world ---@type table
  if type(world) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_WORLD_INVALID, "field save world must be a table", {})
  end
  if type(world.objects) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_WORLD_INVALID, "field save world objects must be a table", {})
  end
  local flags = world.flags ---@type table
  local variables = world.variables ---@type table
  local eventStateInput = { flags = flags, vars = variables } ---@type table
  local ok, err = pcall(FieldEventState.new, eventStateInput)
  ---@cast ok boolean
  ---@cast err Errors.Error
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
  if world.fieldMusicOverride ~= nil then
    if
      type(world.fieldMusicOverride) ~= "number"
      or world.fieldMusicOverride ~= math.floor(world.fieldMusicOverride)
      or world.fieldMusicOverride < 0
      or world.fieldMusicOverride ~= world.fieldMusicOverride
      or world.fieldMusicOverride == math.huge
      or world.fieldMusicOverride == -math.huge
    then
      Errors.raise(
        FieldErrors.FIELD_SAVE_WORLD_INVALID,
        "field save world fieldMusicOverride must be a non-negative integer",
        { fieldMusicOverride = world.fieldMusicOverride }
      )
    end
  end
end

-- The scripts bucket, validated by the caller's `opts.scriptsValidate`
-- (the game layer wires ScriptSave.validate for it).
---@param record table
---@param opts table?
local function validateScripts(record, opts)
  if type(record.scripts) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_SCRIPTS_INVALID, "field save scripts bucket is required", {})
  end
  if opts and opts.scriptsValidate then
    local validateScriptsFn = opts.scriptsValidate ---@type fun(table): Errors.Error?
    local err = validateScriptsFn(record.scripts)
    if err ~= nil then
      Errors.raise(
        FieldErrors.FIELD_SAVE_SCRIPTS_INVALID,
        "field save scripts bucket is invalid: " .. tostring(err.message),
        { cause = err.code }
      )
    end
  end
end

---@param record table
local function validateAuxiliaryUi(record)
  local auxiliaryUi = record.auxiliaryUi ---@type table
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
-- rejected, never defaulted or upgraded. Returns the canonical player-data
-- record the model produces (unknown keys discarded), so the validated save
-- record never hands the runtime the raw deserialized bucket. The context
-- itself is a required composition contract: without it no call path may
-- accept player data, so a missing context is a programming fault, not a
-- validation downgrade.
---@param record table
---@param opts table?
---@return table
local function validatePlayerData(record, opts)
  if type(record.playerData) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_PLAYER_DATA_INVALID, "field save player data bucket is required", {})
  end
  local context = opts and opts.playerDataContext
  assert(
    type(context) == "table" and type(context.charmap) == "table" and type(context.frameIndexes) == "table",
    "field save player-data validation requires the generated charmap and frame-index context"
  )
  local valid, err = FieldPlayerData.validate(record.playerData, context)
  if not valid then
    ---@cast err Errors.Error
    Errors.raise(FieldErrors.FIELD_SAVE_PLAYER_DATA_INVALID, "field save player data is invalid: " .. tostring(err), {
      cause = err.code,
    })
  end
  return assert(valid)
end

-- Strict schema validation (raising). Returns a shallow copy of the record
-- whose player-data bucket is the canonical record produced by the player
-- model: the deserialized bucket is validated exactly once here, and restore
-- operates on this canonical record.
---@param record table
---@param opts table?
---@return table
local function validate(record, opts)
  if type(record) ~= "table" then
    Errors.raise(FieldErrors.FIELD_SAVE_INVALID, "field save must be a table", {})
  end
  if record.schema ~= FieldSave.SCHEMA then
    Errors.raise(FieldErrors.FIELD_SAVE_SCHEMA_UNSUPPORTED, "unsupported field save schema", { schema = record.schema })
  end
  validateFieldState(record)
  validateAvatar(record, opts)
  validateWorld(record)
  validateScripts(record, opts)
  validateAuxiliaryUi(record)
  local canonicalPlayerData = validatePlayerData(record, opts)
  local canonical = {} ---@type table
  local source = record ---@type table<string, unknown>
  for key in pairs(source) do
    canonical[tostring(key)] = source[key]
  end
  local result = canonical ---@cast result FieldSave.Record
  result.playerData = canonicalPlayerData
  return result
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

-- True only when a stable tile boundary can be captured: the player idle,
-- no transition active, no half-open modal dialogue, presented signpost
-- window, or active application (the Start Menu, an application fade, or a
-- child application). Transient audio has no save-stability concept of its
-- own (it is discarded on load and the restored wait tasks complete against
-- the fresh audio service), so the gate never consults the audio
-- collaborator.
---@param session FieldSave.Session|FieldSession?
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

---@param session FieldSave.Session
---@param opts table
---@return table record
function FieldSave.capture(session, opts)
  assert(FieldSave.canCapture(session), "field save requires an idle tile boundary")
  assert(opts and type(opts.avatarId) == "string" and opts.avatarId ~= "", "field save capture requires an avatar id")
  assert(type(opts.world) == "table", "field save capture requires a world bucket")
  assert(type(opts.scriptsBucket) == "table", "field save capture requires a scripts bucket")
  assert(type(opts.auxiliaryUi) == "table", "field save capture requires auxiliary UI state")
  assert(type(opts.playerData) == "table", "field save capture requires the player-data bucket")
  local player = session.player
  local runtimeMap = session.currentMap
  local captureOptions = opts
  ---@cast captureOptions FieldSave.CaptureOptions
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
    avatar = captureOptions.avatarId,
    world = captureOptions.world,
    scripts = captureOptions.scriptsBucket,
    auxiliaryUi = captureOptions.auxiliaryUi,
    playerData = captureOptions.playerData,
  }
end

---@param localX number
---@param localZ number
---@param savedY number
---@return FieldSave.Surface
---@param runtimeMap FieldSave.RuntimeMap
local function closestSurface(runtimeMap, localX, localZ, savedY)
  local terrain = assert(runtimeMap.terrain)
  local samples = {} ---@type FieldSave.Surface[]
  local candidates =
    terrain:candidatesAt(localX + FieldCoordinates.TILE_CENTER_OFFSET, localZ + FieldCoordinates.TILE_CENTER_OFFSET)
  ---@cast candidates table[]
  for _, plate in ipairs(candidates) do
    local sample = terrain:sample(
      plate.id,
      localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ + FieldCoordinates.TILE_CENTER_OFFSET
    )
    ---@cast sample FieldSave.Surface
    local sampleRecord = sample
    sampleRecord.distance = math.abs(sampleRecord.worldY - savedY)
    samples[#samples + 1] = sampleRecord
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
  return assert(samples[1])
end

-- Strict restore of the only schema. Returns the restored location plus the
-- persisted avatar id, world and scripts buckets, auxiliary UI state, and
-- the canonical player-data record, so the caller rebuilds exactly what the
-- save holds. `opts.scriptsValidate` is the domain validator wired by the
-- game layer (ScriptSave.validate for the scripts bucket);
-- `opts.playerDataContext` is the player-data validation context; the world
-- bucket is validated by this boundary itself.
---@param record table
---@param loader table
---@param expectedVersionId string
---@param opts table
---@return table
local function restore(record, loader, expectedVersionId, opts)
  local canonical = validate(record, opts)
  ---@cast canonical FieldSave.Record
  if canonical.versionId ~= expectedVersionId then
    Errors.raise(
      FieldErrors.FIELD_SAVE_VERSION_MISMATCH,
      "field save belongs to another imported version",
      { expected = expectedVersionId, actual = canonical.versionId }
    )
  end
  local logicalMap = loader:load(canonical.mapId, { fieldX = canonical.fieldX, fieldZ = canonical.fieldZ })
  local composeRuntimeMap = opts.composeRuntimeMap
  local runtimeMap = composeRuntimeMap
      and composeRuntimeMap(logicalMap, { fieldX = canonical.fieldX, fieldZ = canonical.fieldZ })
    or logicalMap
  ---@cast runtimeMap FieldSave.RuntimeMap
  local localX, localZ = FieldCoordinates.fieldToLocal(runtimeMap, canonical.fieldX, canonical.fieldZ) ---@type number, number
  local terrain = assert(runtimeMap.terrain)
  local surface ---@type FieldSave.Surface
  if
    canonical.terrainDependencyHash == runtimeMap.terrainDependencyHash
    and terrain:contains(
      canonical.surfaceId,
      localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ + FieldCoordinates.TILE_CENTER_OFFSET
    )
  then
    surface = terrain:sample(
      canonical.surfaceId,
      localX + FieldCoordinates.TILE_CENTER_OFFSET,
      localZ + FieldCoordinates.TILE_CENTER_OFFSET
    )
    ---@cast surface FieldSave.Surface
  else
    surface = closestSurface(runtimeMap, localX, localZ, canonical.worldY)
  end
  local suppression ---@type table?
  if WarpSystem.findAt(runtimeMap, canonical.fieldX, canonical.fieldZ) then
    suppression = { mapId = runtimeMap.mapId, fieldX = canonical.fieldX, fieldZ = canonical.fieldZ }
  end
  return {
    runtimeMap = runtimeMap,
    fieldX = canonical.fieldX,
    fieldZ = canonical.fieldZ,
    worldY = surface.worldY,
    surfaceId = surface.surfaceId,
    facing = canonical.facing,
    suppression = suppression,
    avatar = canonical.avatar,
    world = canonical.world,
    scripts = canonical.scripts,
    auxiliaryUi = canonical.auxiliaryUi,
    playerData = canonical.playerData,
  }
end

---@param record table
---@param loader table
---@param expectedVersionId string
---@param opts table?
---@return table?, Errors.Error?
function FieldSave.restore(record, loader, expectedVersionId, opts)
  assert(loader and loader.load, "field save restore loader required")
  local ok, result = pcall(restore, record, loader, expectedVersionId, opts or {})
  if ok then
    ---@cast result table
    return result
  end
  if Errors.is(result) then
    ---@cast result Errors.Error
    return nil, result
  end
  error(result)
end

return FieldSave
