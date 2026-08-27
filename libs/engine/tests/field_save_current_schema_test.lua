-- Current field-save contract: captures persist the state needed to resume,
-- but no initialization identity, and the previous exact schema is rejected.

local Assert = require("tests.support.Assert")
local FieldSave = require("libs.engine.src.FieldSave")
local PlayerDataContext = require("tests.support.PlayerDataContext")

local T = {
  metadata = {
    tags = { "field", "persistence", "schema" },
  },
  tests = {},
}

local function session()
  return {
    versionId = "heartgold",
    currentMap = { mapId = 60, terrainDependencyHash = "terrain" },
    player = {
      fieldX = 684,
      fieldZ = 393,
      worldY = 4,
      surfaceId = 11,
      facing = "north",
      motion = "idle",
    },
    transition = { phase = "idle" },
    dialogue = {
      isModal = function()
        return false
      end,
    },
    signpost = {
      isModal = function()
        return false
      end,
    },
    applicationHost = {
      isActive = function()
        return false
      end,
    },
  }
end

local function playerData()
  return {
    profile = { name = "GOLD", gender = 0, trainerId = 0 },
    options = { textFrame = 0, textSpeed = "mid" },
  }
end

local function world()
  return { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } }
end

local function currentRecord()
  return FieldSave.capture(session(), {
    avatarId = "hero",
    world = world(),
    scriptsBucket = {},
    auxiliaryUi = { requested = "shown", state = "shown" },
    playerData = playerData(),
  })
end

local function previousRecord()
  return {
    schema = "g4-field-save-v3",
    versionId = "heartgold",
    mapId = 60,
    fieldX = 684,
    fieldZ = 393,
    worldY = 4,
    surfaceId = 11,
    terrainDependencyHash = "terrain",
    facing = "north",
    avatar = "hero",
    scenario = "pre-script-demo-v1",
    world = world(),
    scripts = {},
    auxiliaryUi = { requested = "shown", state = "shown" },
    playerData = playerData(),
  }
end

function T.tests.capture_and_validation_persist_current_state_without_initialization_identity()
  local saved = currentRecord()
  Assert.equal(saved.schema, "g4-field-save-v4")
  Assert.isNil(saved.scenario, "current captures must not contain an initialization identity")

  local validated = assert(FieldSave.validate(saved, {
    avatars = { hero = true },
    playerDataContext = PlayerDataContext.new(),
  }))
  Assert.isNil(validated.scenario, "validated current saves must not restore an initialization identity")

  local legacy = {}
  for key, value in pairs(saved) do
    legacy[key] = value
  end
  legacy.schema = "g4-field-save-v3"
  local restored, err = FieldSave.validate(legacy, {
    avatars = { hero = true },
    playerDataContext = PlayerDataContext.new(),
  })
  Assert.isNil(restored, "the previous exact schema must not be accepted after the schema bump")
  Assert.equal(assert(err).code, "FIELD_SAVE_SCHEMA_UNSUPPORTED")
end

function T.tests.previous_save_schema_is_rejected_after_the_schema_bump()
  local restored, err = FieldSave.validate(previousRecord(), {
    avatars = { hero = true },
    playerDataContext = PlayerDataContext.new(),
  })
  Assert.isNil(restored, "the previous exact schema must not remain valid")
  Assert.equal(assert(err).code, "FIELD_SAVE_SCHEMA_UNSUPPORTED")
end

return T
