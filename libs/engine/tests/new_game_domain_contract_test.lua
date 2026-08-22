-- Contract tests for the pure domain state that carries a new game from menu
-- creation through profile finalization and playable-field time. Storage,
-- randomness, and civil time are injected boundaries; no LÖVE or filesystem
-- state is needed here.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")

local T = {}

local CHARMAP = {
  A = 299,
  B = 300,
  C = 301,
  D = 302,
  E = 303,
  F = 304,
  G = 305,
  O = 313,
  L = 310,
  Q = 315,
  U = 321,
  R = 316,
}

local FRAME_INDEXES = { [0] = true, [1] = true, [2] = true }

local function requireDomain(moduleName, behavior)
  local ok, result = pcall(require, moduleName)
  if ok then
    return result
  end
  error(behavior .. " is not available", 0)
end

local function playerDataContext()
  return { charmap = CHARMAP, frameIndexes = FRAME_INDEXES }
end

local function reservationService()
  local calls = { reserve = 0, publish = 0, save = 0 }
  return {
    calls = calls,
    reserve = function(_, versionId)
      calls.reserve = calls.reserve + 1
      Assert.equal(versionId, "heartgold")
      return 41
    end,
    publish = function()
      calls.publish = calls.publish + 1
    end,
    save = function()
      calls.save = calls.save + 1
    end,
  }
end

local function newCandidate(service)
  local NewGame = requireDomain("libs.engine.src.NewGame", "new-game candidate creation")
  return NewGame.createCandidate({
    saveService = service,
    versionId = "heartgold",
    eventState = FieldEventState.new(),
    scriptSymbols = FieldScriptSymbols,
    mapIdentity = {
      mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
      fieldX = 6,
      fieldZ = 6,
      sourceFacing = 1,
    },
  })
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured domain error")
  Assert.equal(err.code, code)
end

function T.new_candidate_uses_source_owned_opening_state()
  local service = reservationService()
  local candidate = newCandidate(service)
  local openingFlag = FieldScriptSymbols.flagsByName.FLAG_UNK_960

  Assert.equal(service.calls.reserve, 1, "New Game reserves exactly one stable identity")
  Assert.equal(candidate.saveId, 41)
  Assert.equal(candidate.versionId, "heartgold")
  Assert.deepEqual(candidate.location, {
    mapSymbol = "MAP_NEW_BARK_PLAYER_HOUSE_2F",
    fieldX = 6,
    fieldZ = 6,
    facing = "south",
  })
  Assert.equal(candidate.profileDraft.money, 3000)
  Assert.deepEqual(candidate.options, { textSpeed = "mid", textFrame = 0 })
  Assert.equal(candidate.playTime:seconds(), 0)
  Assert.isTrue(candidate.worldState:isFlagSet(openingFlag), "the source opening flag is seeded semantically")
  Assert.isNil(candidate.surfaceId, "surface resolution belongs to field entry")
  Assert.isNil(candidate.worldState.fishingRecord, "unowned retail buckets are not fabricated")
  Assert.equal(service.calls.publish, 0)
  Assert.equal(service.calls.save, 0)
end

function T.player_data_validates_source_shaped_profile_and_defaults()
  local PlayerData = requireDomain("libs.engine.src.PlayerData", "generalized PlayerData validation")
  local defaults = assert(PlayerData.defaultOptions())
  Assert.deepEqual(defaults, { textSpeed = "mid", textFrame = 0 })

  local valid = assert(PlayerData.validate({
    profile = { name = "ABCDEFG", gender = 0, trainerId = 0, money = 0 },
    options = defaults,
  }, playerDataContext()))
  Assert.equal(valid.profile.money, 0)

  valid = assert(PlayerData.validate({
    profile = { name = "GOLD", gender = 1, trainerId = 0, money = 999999 },
    options = { textSpeed = "fast", textFrame = 2 },
  }, playerDataContext()))
  Assert.equal(valid.profile.money, 999999)

  for _, name in ipairs({ "", "ABCDEFGH", "G?LD" }) do
    throwsCode("PLAYER_DATA_NAME_INVALID", function()
      local _, err = PlayerData.validate({
        profile = { name = name, gender = 0, trainerId = 0, money = 3000 },
        options = defaults,
      }, playerDataContext())
      error(err)
    end)
  end
  for _, gender in ipairs({ -1, 2, 0.5, "male" }) do
    throwsCode("PLAYER_DATA_GENDER_INVALID", function()
      local _, err = PlayerData.validate({
        profile = { name = "GOLD", gender = gender, trainerId = 0, money = 3000 },
        options = defaults,
      }, playerDataContext())
      error(err)
    end)
  end
  for _, money in ipairs({ -1, 1000000, 1.5, "3000" }) do
    throwsCode("PLAYER_DATA_MONEY_INVALID", function()
      local _, err = PlayerData.validate({
        profile = { name = "GOLD", gender = 0, trainerId = 0, money = money },
        options = defaults,
      }, playerDataContext())
      error(err)
    end)
  end
  throwsCode("PLAYER_DATA_TEXT_SPEED_INVALID", function()
    local _, err = PlayerData.validate({
      profile = { name = "GOLD", gender = 0, trainerId = 0, money = 3000 },
      options = { textSpeed = "turbo", textFrame = 0 },
    }, playerDataContext())
    error(err)
  end)
end

function T.trainer_identity_preserves_u32_and_exposes_only_the_visible_low_half()
  local PlayerData = requireDomain("libs.engine.src.PlayerData", "full trainer identity")
  for _, example in ipairs({
    { stored = 0, visible = 0 },
    { stored = 65536, visible = 0 },
    { stored = 0xFFFFFFFF, visible = 65535 },
  }) do
    local validated = assert(PlayerData.validate({
      profile = { name = "GOLD", gender = 0, trainerId = example.stored, money = 3000 },
      options = { textSpeed = "mid", textFrame = 0 },
    }, playerDataContext()))
    Assert.equal(validated.profile.trainerId, example.stored)
    Assert.equal(PlayerData.visibleTrainerId(example.stored), example.visible)
  end
  for _, trainerId in ipairs({ -1, 0x100000000, 1.5, "12" }) do
    throwsCode("PLAYER_DATA_TRAINER_ID_INVALID", function()
      local _, err = PlayerData.validate({
        profile = { name = "GOLD", gender = 0, trainerId = trainerId, money = 3000 },
        options = { textSpeed = "mid", textFrame = 0 },
      }, playerDataContext())
      error(err)
    end)
  end
end

function T.local_clock_is_the_validated_injectable_civil_time_boundary()
  local LocalClock = requireDomain("libs.engine.src.LocalClock", "injectable local civil time")
  local current = { year = 2026, month = 8, day = 22, hour = 3, minute = 59, second = 58 }
  local calls = 0
  local clock = LocalClock.new(function()
    calls = calls + 1
    return current
  end)

  Assert.deepEqual(clock:nowLocal(), current)
  current = { year = 2026, month = 8, day = 22, hour = 4, minute = 0, second = 0 }
  Assert.deepEqual(clock:nowLocal(), current)
  Assert.equal(calls, 2, "consumers sample one injected civil-time boundary")
  Assert.throws(function()
    LocalClock.new(function()
      return { year = 2026, month = 13, day = 22, hour = 4, minute = 0, second = 0 }
    end):nowLocal()
  end)
end

function T.play_time_excludes_pre_field_time_includes_active_modals_and_caps()
  local PlayTime = requireDomain("libs.engine.src.PlayTime", "capped active-game play time")
  local playTime = PlayTime.new()

  playTime:advance(600)
  Assert.equal(playTime:seconds(), 0, "menu and Oak time are excluded before field entry")
  playTime:start()
  playTime:advance(17)
  playTime:advance(3599982)
  Assert.equal(playTime:seconds(), 3599999)
  playTime:advance(600, { modal = "trainer-card" })
  Assert.equal(playTime:seconds(), 3599999, "active modal time remains capped, never wrapped")
end

function T.partial_candidate_finalizes_after_confirmation_without_publishing_gameplay()
  local service = reservationService()
  local candidate = newCandidate(service)
  local NewGame = requireDomain("libs.engine.src.NewGame", "new-game profile finalization")

  Assert.isNil(candidate.playerData, "Oak receives a partial candidate, not a fake final profile")
  local finalized = assert(NewGame.finalize(candidate, {
    name = "GOLD",
    gender = 0,
  }, {
    randomU32 = function()
      return 0xFFFFFFFF
    end,
    playerDataContext = playerDataContext(),
  }))

  Assert.equal(finalized.saveId, 41)
  Assert.equal(finalized.playerData.profile.name, "GOLD")
  Assert.equal(finalized.playerData.profile.gender, 0)
  Assert.equal(finalized.playerData.profile.trainerId, 0xFFFFFFFF)
  Assert.equal(finalized.playerData.profile.money, 3000)
  Assert.equal(service.calls.reserve, 1)
  Assert.equal(service.calls.publish, 0, "finalization is not first Save")
  Assert.equal(service.calls.save, 0, "finalization does not publish a gameplay payload")
end

return { tests = T }
