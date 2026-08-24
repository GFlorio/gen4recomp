-- FieldRuntime accepts one finalized or loaded game record and does not own
-- fresh-session policy, demo manifests, or save-store loading.

local Assert = require("tests.support.Assert")
local GameSave = require("libs.engine.src.GameSave")
local FieldRuntime = require("game.src.game.FieldRuntime")
local PlayTime = require("libs.engine.src.PlayTime")

local T = {}

---@class FieldRuntimeGameEntryTestRuntime : FieldRuntime
---@field entryLoaded boolean?
---@field mapIdOrSymbol string|integer|nil

function T.constructor_uses_the_supplied_game_entry_record()
  local originalLoad = FieldRuntime._load
  local entry = {
    saveId = "save-00000001",
    versionId = "heartgold",
    location = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    playTime = PlayTime.new(),
    worldState = {},
  }

  ---@param self FieldRuntimeGameEntryTestRuntime
  FieldRuntime._load = function(self)
    self.entryLoaded = self.game == entry
  end

  local ok, runtime = pcall(FieldRuntime.new, entry, { presentation = false })
  FieldRuntime._load = originalLoad
  Assert.isTrue(ok, tostring(runtime))
  ---@cast runtime FieldRuntimeGameEntryTestRuntime
  Assert.isTrue(runtime.entryLoaded, "the runtime must retain the supplied game entry")
  Assert.equal(runtime.versionId, "heartgold")
  Assert.isNil(runtime.mapIdOrSymbol, "the runtime must not select a default map")
end

function T.default_save_validation_uses_repository_overrides()
  local originalLoad = FieldRuntime._load
  local entry = {
    saveId = "save-00000001",
    versionId = "heartgold",
    location = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      facing = "south",
    },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    playTime = PlayTime.new(),
    worldState = {},
  }

  FieldRuntime._load = function() end
  local ok, runtime = pcall(FieldRuntime.new, entry, { presentation = false })
  FieldRuntime._load = originalLoad

  Assert.isTrue(ok, tostring(runtime))
  local overrideManifest = runtime.saveValidation.overrideFs:read("data/scripts/manifests/overrides.lua")
  Assert.notNil(overrideManifest, "default save validation needs repository overrides")
end

local function captureRuntime(overrides)
  local runtime = setmetatable({
    game = {
      saveId = "save-00000001",
      versionId = "heartgold",
    },
    saveId = "save-00000001",
    versionId = "heartgold",
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 1, money = 3000 },
      options = { textSpeed = "mid", textFrame = 0 },
    },
    session = {
      tick = 42,
      player = {
        motion = "idle",
        fieldX = 684,
        fieldZ = 393,
        worldY = 1.5,
        surfaceId = 2,
        facing = "south",
      },
      currentMap = { mapId = 60, terrainDependencyHash = "terrain-heartgold" },
    },
    scripts = {
      worldState = {
        capture = function()
          return { flags = { [960] = true }, variables = {}, objects = {}, rng = { state = 1, calls = 2 } }
        end,
      },
      scheduler = {},
      registryFingerprint = function()
        return "registry-fingerprint"
      end,
    },
    auxiliaryFieldUi = {
      capture = function()
        return { requested = "shown", state = "shown" }
      end,
    },
    audio = {
      musicOverride = function()
        return 123
      end,
    },
    playTime = PlayTime.new(17),
    saveValidation = {
      contexts = {},
      contextLoader = function()
        return {}
      end,
      validate = function(_, record)
        return record
      end,
    },
  }, FieldRuntime)
  for key, value in pairs(overrides or {}) do
    runtime[key] = value
  end
  return runtime
end

function T.captureGameSave_returns_a_strict_snapshot_without_storage_io()
  local runtime = captureRuntime()
  local validationCalls = 0
  runtime.saveValidation = {
    contexts = {},
    contextLoader = function()
      return {}
    end,
    validate = function(_, record)
      validationCalls = validationCalls + 1
      return record
    end,
  }
  local scriptCaptureCalls = 0
  local originalCapture = require("libs.engine.src.script.ScriptSave").capture
  ---@diagnostic disable-next-line: duplicate-set-field
  require("libs.engine.src.script.ScriptSave").capture = function(scheduler, tick, options)
    scriptCaptureCalls = scriptCaptureCalls + 1
    Assert.equal(tick, 42)
    Assert.equal(options.registryFingerprint, "registry-fingerprint")
    return { schema = "g4-script-save-v1", capturedAtSimulationTick = tick }
  end

  local ok, result = pcall(function()
    return runtime:captureGameSave()
  end)
  require("libs.engine.src.script.ScriptSave").capture = originalCapture

  Assert.isTrue(ok, tostring(result))
  local valid = assert(GameSave.validate(result))
  Assert.equal(valid.saveId, "save-00000001")
  Assert.equal(valid.versionId, "heartgold")
  Assert.equal(valid.mapId, 60)
  Assert.equal(valid.fieldX, 684)
  Assert.equal(valid.fieldZ, 393)
  Assert.equal(valid.surfaceId, 2)
  Assert.equal(valid.worldY, 1.5)
  Assert.equal(valid.playTimeSeconds, 17)
  Assert.equal(valid.audio.fieldMusicOverride, 123)
  Assert.equal(scriptCaptureCalls, 1)
  Assert.equal(validationCalls, 1)
end

function T.captureGameSave_refuses_an_unstable_boundary_without_mutating_state()
  local runtime = captureRuntime()
  runtime.session.player.motion = "walking"
  local snapshot, reason = runtime:captureGameSave()
  Assert.isNil(snapshot)
  Assert.isTrue(type(reason) == "string" and reason ~= "")
  Assert.equal(runtime.session.player.motion, "walking")
end

function T.warp_completion_does_not_request_an_implicit_save()
  local saveRequests = 0
  local completionConsumed = false
  local runtime = setmetatable({
    presentationFrameAccumulator = 0,
    audioFrameAccumulator = 0,
    scripts = {},
    session = {
      accumulator = 0,
      updateFixed = function() end,
    },
    transition = {
      error = nil,
      phase = "idle",
      updateSourceFrame = function() end,
      consumeCompleted = function()
        completionConsumed = true
        return true
      end,
    },
    applicationHost = {
      error = function()
        return nil
      end,
    },
    playTime = {
      advance = function() end,
    },
  }, FieldRuntime)
  runtime:update(0)

  Assert.isTrue(completionConsumed, "the transition completion edge is consumed")
  Assert.equal(saveRequests, 0, "completing a warp must not publish or request a checkpoint")
end

function T.update_advances_play_time_once_even_when_fixed_ticks_are_dropped()
  local advances = {}
  local runtime = setmetatable({
    presentationFrameAccumulator = 0,
    audioFrameAccumulator = 0,
    scripts = {},
    session = {
      accumulator = 0,
      updateFixed = function() end,
    },
    transition = {
      error = nil,
      phase = "idle",
      updateSourceFrame = function() end,
      consumeCompleted = function()
        return false
      end,
    },
    applicationHost = {
      error = function()
        return nil
      end,
    },
    playTime = {
      advance = function(_, dt)
        advances[#advances + 1] = dt
      end,
    },
  }, FieldRuntime)
  runtime:update(123.5)
  Assert.deepEqual(advances, { 123.5 })
end

function T.manual_save_keeps_publication_state_across_menu_openings()
  local calls = {}
  local runtime = setmetatable({
    savePublished = false,
    saveStore = {
      publishFirst = function(_, record)
        calls[#calls + 1] = { kind = "publish", record = record }
      end,
      save = function(_, record)
        calls[#calls + 1] = { kind = "update", record = record }
      end,
    },
  }, FieldRuntime)
  runtime._captureManualSaveFromMenu = function()
    return { saveId = "save-00000001" }
  end
  runtime:_saveCheckpoint()
  runtime:_saveCheckpoint()
  Assert.equal(runtime.savePublished, true)
  Assert.deepEqual({ calls[1].kind, calls[2].kind }, { "publish", "update" })
end

function T.failed_first_manual_save_remains_retryable_as_first_publication()
  local attempts = 0
  local runtime = setmetatable({
    savePublished = false,
    saveStore = {
      publishFirst = function()
        attempts = attempts + 1
        if attempts == 1 then
          error("publication failed")
        end
      end,
    },
  }, FieldRuntime)
  runtime._captureManualSaveFromMenu = function()
    return { saveId = "save-00000001" }
  end
  Assert.throws(function()
    runtime:_saveCheckpoint()
  end)
  Assert.equal(runtime.savePublished, false)
  runtime:_saveCheckpoint()
  Assert.equal(runtime.savePublished, true)
  Assert.equal(attempts, 2)
end

function T.dispose_releases_runtime_without_capturing_or_persisting()
  local captures = 0
  local runtime = captureRuntime()
  runtime.captureGameSave = function()
    captures = captures + 1
    error("dispose must not capture")
  end
  runtime._releaseAll = function(self)
    self.session = nil
  end
  runtime:dispose()
  Assert.equal(captures, 0)
  Assert.isNil(runtime.session)
end

return { tests = T }
