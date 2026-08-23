-- Production-facing save contracts: the application validator rejects malformed
-- persisted buckets, and the global catalog exposes those records as unavailable.

local Assert = require("tests.support.Assert")
local FakeCache = require("tests.support.FakeCache")
local SaveFs = require("libs.storage.src.SaveFs")
local GameSaveStore = require("libs.engine.src.GameSaveStore")
local GameSave = require("libs.engine.src.GameSave")
local GameSaveValidation = require("game.src.game.GameSaveValidation")
local MainMenuState = require("game.src.game.MainMenuState")
local Errors = require("libs.errors.src.Errors")

local T = {
  metadata = {
    tags = { "save", "catalog", "main-menu", "product" },
  },
  tests = {},
}

---@class SaveCatalogStore : GameSaveStore
---@field reserve fun(self: SaveCatalogStore): string
---@field publishFirst fun(self: SaveCatalogStore, record: table): boolean
---@field list fun(self: SaveCatalogStore): table[]
---@field delete fun(self: SaveCatalogStore, saveId: string): boolean

local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy(child)
  end
  return result
end

local function context()
  return {
    charmap = { G = 1, O = 2, L = 3, D = 4 },
    frameIndexes = { [0] = true },
    audioSequenceIds = { [7] = true },
    scriptCompatibility = {
      validationOptions = function()
        return {
          expectedRegistryFingerprint = "registry",
          expectedTaskFingerprint = "tasks",
          resolveTask = function()
            return nil
          end,
          resolveComposition = function()
            return nil
          end,
        }
      end,
    },
  }
end

local function validRecord()
  return {
    schema = "g4-game-save-v1",
    saveId = "save-00000001",
    versionId = "heartgold",
    playTimeSeconds = 0,
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 0,
    surfaceId = 0,
    terrainDependencyHash = "terrain-heartgold",
    facing = "south",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = {
      schema = "g4-script-save-v1",
      registryFingerprint = "registry",
      taskFingerprint = "tasks",
      capturedAtSimulationTick = 0,
      nextEnvironmentId = 0,
      nextInstanceId = 0,
      nextTaskId = 0,
      environments = {},
      instances = {},
      tasks = {},
    },
    auxiliaryUi = { requested = "shown", state = "shown" },
    audio = { fieldMusicOverride = 7 },
  }
end

local function validator()
  return GameSaveValidation.new({
    contextLoader = function()
      return context()
    end,
  })
end

local function assertRejected(service, record, label)
  local validated, err = service:validate(record)
  Assert.isNil(validated, label .. " must be rejected")
  Assert.isTrue(Errors.is(err), label .. " must return a typed validation error")
end

function T.tests.global_validation_rejects_malformed_gameplay_buckets()
  local service = validator()
  local baseline = validRecord()
  Assert.notNil(service:validate(baseline), "the captured save shape must remain valid")

  local mutations = {
    world_flag_value = function(record)
      record.world.flags[12] = false
    end,
    world_variable_value = function(record)
      record.world.variables[12] = 0x10000
    end,
    world_rng_state = function(record)
      record.world.rng.state = 0
    end,
    world_objects = function(record)
      record.world.objects.object = {}
    end,
    missing_script_fingerprint = function(record)
      record.scripts.registryFingerprint = nil
    end,
    contradictory_auxiliary_ui = function(record)
      record.auxiliaryUi = { requested = "hidden", state = "showing" }
    end,
    unknown_audio_sequence = function(record)
      record.audio.fieldMusicOverride = 999
    end,
  }

  for label, mutate in pairs(mutations) do
    local candidate = copy(baseline)
    mutate(candidate)
    assertRejected(service, candidate, label)
    Assert.notNil(service:validate(baseline), "" .. label .. " must not mutate the baseline")
  end

  local transitional = copy(baseline)
  transitional.auxiliaryUi = { requested = "shown", state = "showing" }
  Assert.notNil(service:validate(transitional), "a valid auxiliary UI transition must pass")

  local noOverride = copy(baseline)
  noOverride.audio = {}
  Assert.notNil(service:validate(noOverride), "an omitted audio override must pass")
end

function T.tests.catalog_lists_corrupt_save_as_unavailable_before_continue()
  local backend = FakeCache.new()
  local saveFs = SaveFs.global(backend)
  local service = validator()
  local store = GameSaveStore.new(saveFs, {
    recordValidate = function(record)
      return service:validate(record)
    end,
  })

  local record = validRecord()
  ---@diagnostic disable-next-line: undefined-field
  Assert.equal(store:reserve(), record.saveId)
  ---@diagnostic disable-next-line: undefined-field
  Assert.isTrue(store:publishFirst(record))

  local corrupt = copy(record)
  corrupt.world.objects.unrestored = true
  Assert.isTrue(saveFs:writeLua("games/" .. record.saveId .. ".lua", corrupt))

  ---@diagnostic disable-next-line: undefined-field
  local entries = store:list()
  Assert.equal(#entries, 1)
  Assert.equal(entries[1].saveId, record.saveId)
  Assert.notNil(entries[1].error, "catalog listing must preserve the typed save validation failure")
  Assert.isTrue(Errors.is(entries[1].error))

  local menu = MainMenuState.new({
    saveStore = store,
    readyVersions = { "heartgold" },
    width = 960,
    height = 540,
  })
  local item = menu:view().items[2]
  Assert.equal(item.saveId, record.saveId)
  Assert.isFalse(item.canContinue, "a corrupt save must not be Continue-eligible")
  Assert.isTrue(type(item.errorSummary) == "string" and item.errorSummary ~= "")
  Assert.isNil(item.playerName)
  Assert.isNil(item.playTimeLabel)
  menu:dispose()
end

function T.tests.catalog_lists_stale_script_identity_as_unavailable_before_continue()
  local backend = FakeCache.new()
  local saveFs = SaveFs.global(backend)
  local service = validator()
  ---@type { reserve: fun(self: table): string, publishFirst: fun(self: table, record: table): boolean, list: fun(self: table): table[] }
  local store = GameSaveStore.new(saveFs, {
    recordValidate = function(record)
      return service:validate(record)
    end,
  })
  local publisher = GameSaveStore.new(saveFs, { recordValidate = GameSave.validate })
  ---@cast store SaveCatalogStore
  ---@cast publisher SaveCatalogStore

  local record = validRecord()
  record.scripts.registryFingerprint = "stale-registry"
  Assert.equal(publisher:reserve(), record.saveId)
  Assert.isTrue(publisher:publishFirst(record))

  local entries = store:list()
  Assert.equal(#entries, 1)
  Assert.equal(entries[1].saveId, record.saveId)
  Assert.notNil(entries[1].error, "a stale script identity must be rejected during catalog validation")
  Assert.isTrue(Errors.is(entries[1].error))

  local menu = MainMenuState.new({
    saveStore = store,
    readyVersions = { "heartgold" },
    width = 960,
    height = 540,
  })
  local item = menu:view().items[2]
  Assert.equal(item.saveId, record.saveId)
  Assert.isFalse(item.canContinue, "a stale script identity must not be Continue-eligible")
  Assert.isTrue(type(item.errorSummary) == "string" and item.errorSummary ~= "")

  local deleted = store:delete(record.saveId)
  Assert.isTrue(deleted, "an unavailable save must remain deletable")
  Assert.equal(#store:list(), 0)
  menu:dispose()
end

function T.tests.catalog_lists_impossible_rng_state_as_unavailable_before_continue()
  local backend = FakeCache.new()
  local saveFs = SaveFs.global(backend)
  local service = validator()
  local store = GameSaveStore.new(saveFs, {
    recordValidate = function(record)
      return service:validate(record)
    end,
  })
  ---@cast store SaveCatalogStore
  local publisher = GameSaveStore.new(saveFs, { recordValidate = GameSave.validate })
  ---@cast publisher SaveCatalogStore

  local record = validRecord()
  record.world.rng.state = 0x7FFFFFFF
  Assert.equal(publisher:reserve(), record.saveId)
  Assert.isTrue(publisher:publishFirst(record))

  local entries = store:list()
  Assert.equal(#entries, 1)
  Assert.equal(entries[1].saveId, record.saveId)
  Assert.notNil(entries[1].error, "an impossible RNG state must be rejected during catalog validation")
  Assert.isTrue(Errors.is(entries[1].error))

  local menu = MainMenuState.new({
    saveStore = store,
    readyVersions = { "heartgold" },
    width = 960,
    height = 540,
  })
  local item = menu:view().items[2]
  Assert.equal(item.saveId, record.saveId)
  Assert.isFalse(item.canContinue, "an impossible RNG state must not be Continue-eligible")
  Assert.isTrue(type(item.errorSummary) == "string" and item.errorSummary ~= "")
  Assert.isTrue(store:delete(record.saveId), "an unavailable save must remain deletable")
  Assert.equal(#store:list(), 0)
  menu:dispose()
end

return T
