-- Production-composed player-profile and save-schema contracts: the game's
-- player data is the single authority for the profile, so gendered and
-- player-name script text resolve through the real runtime wiring instead of
-- faulting for a missing service, the record survives a fresh-session -> save
-- -> resume round trip, and the current save schema requires the player-data
-- bucket (a record missing it, or at the previous schema, is rejected with
-- the structured error at the resume boundary). The player-data bucket is
-- validated strictly through the generated field-font charmap: a player name
-- containing a real multibyte field-font glyph is accepted and reaches the
-- trainer card presentation through production composition, while an
-- arbitrary empty player-data bucket is rejected -- the resume boundary must
-- never pass player data it did not validate.

local Assert = require("tests.support.Assert")
local LuaWriter = require("libs.codec.src.LuaWriter")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local FieldScenarioManifest = require("data.manifests.field_scenario")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "persistence", "profile", "dialogue", "script" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local WOMAN = { fieldX = 683, fieldZ = 400 }
local TOWN_OW_VARIABLE = FieldScriptSymbols.variablesByName.VAR_SCENE_NEW_BARK_TOWN_OW
local WEST_EXIT_VARIABLE = FieldScriptSymbols.variablesByName.VAR_SCENE_NEW_BARK_WEST_EXIT
-- The New Bark woman's gendered message pair (bank 542): the male variant is
-- selected for profile gender 0, the female variant otherwise.
local GENDERED_MALE_MESSAGE = 6
local GENDERED_FEMALE_MESSAGE = 7

local function requireCapability(game, name)
  Assert.isTrue(
    type(game[name]) == "function",
    "acceptance harness must expose " .. name .. " for production player-data flows"
  )
end

local function withGame(map, fn)
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", map = map, save = "fresh" })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function scriptFaults(game)
  local faults = {}
  for _, record in ipairs(game.hosts.events.records) do
    if record.name == "script.error" then
      faults[#faults + 1] = { scriptId = record.payload.scriptId, code = record.payload.code }
    end
  end
  return faults
end

local function restart(game, options)
  requireCapability(game, "restart")
  return game:restart(options)
end

local function completeDialogue(game)
  requireCapability(game, "advanceDialogue")
  game:advanceDialogue()
  return game:advanceUntil("interaction releases field control", function(snapshot)
    return not snapshot.dialogue.modal and not snapshot.fieldLocked
  end, 480)
end

-- The real runtime profile is wired into the script platform and
-- survives the production save round trip. The bound New Bark woman's
-- gendered conversation (player-name buffer + gendered message) must open
-- from the profile -- not fault with SCRIPT_SERVICE_MISSING -- in both the
-- fresh and the resumed session.
function T.tests.fresh_save_resume_keeps_the_player_profile_driving_gendered_dialogue()
  withGame(TOWN, function(game)
    requireCapability(game, "setWorldState")
    requireCapability(game, "moveTo")
    requireCapability(game, "face")
    requireCapability(game, "pressAction")
    requireCapability(game, "interaction")
    requireCapability(game, "advanceUntil")
    requireCapability(game, "restart")

    -- The script platform must resolve the profile from the runtime wiring;
    -- without the injected player data these fault with SCRIPT_SERVICE_MISSING.
    local gender = game.runtime.scripts.player:gender()
    local name = game.runtime.scripts.player:name()
    Assert.isTrue(#name >= 1 and #name <= 7, "the demo profile name must be a 1..7 glyph name, got " .. tostring(name))
    local expectedMessage = gender == 0 and GENDERED_MALE_MESSAGE or GENDERED_FEMALE_MESSAGE

    -- Route the woman to her gendered conversation: the scene variable outside
    -- 0..2 while the west-exit variable is not 1.
    game:setWorldState({ variable = TOWN_OW_VARIABLE, value = 3 })
    game:setWorldState({ variable = WEST_EXIT_VARIABLE, value = 0 })
    game:moveTo(WOMAN)
    game:face("north")
    game:pressAction()
    Assert.equal(game:interaction().scriptId, "new_bark.npc.woman_1")
    local opened = game:advanceUntil("gendered dialogue opens from the wired player profile", function(snapshot)
      return snapshot.dialogue.modal
    end, 120)
    Assert.equal(opened.dialogue.messageId, expectedMessage)
    Assert.equal(#scriptFaults(game), 0, "the gendered conversation must resolve the profile, not fault")
    completeDialogue(game)

    -- The production save round trip must carry the player-data bucket so the
    -- resumed session resolves the identical profile.
    local resumed = restart(game, { save = "resume" })
    Assert.equal(resumed.saveStatus, "Resumed saved field session")
    Assert.equal(resumed.runtime.scripts.player:gender(), gender)
    Assert.equal(resumed.runtime.scripts.player:name(), name)

    -- The persisted world state keeps the woman on her gendered path and the
    -- restored profile resolves it again without a fault.
    resumed:face("north")
    resumed:pressAction()
    local reopened = resumed:advanceUntil(
      "resumed gendered dialogue opens from the restored player profile",
      function(snapshot)
        return snapshot.dialogue.modal
      end,
      120
    )
    Assert.equal(reopened.dialogue.messageId, expectedMessage)
    Assert.equal(#scriptFaults(resumed), 0, "the resumed gendered conversation must resolve the profile, not fault")
    completeDialogue(resumed)
  end)
end

-- A current-schema session record built from the production runtime's own
-- buckets (world capture, scripts capture), so every other bucket validates.
local function currentSessionRecord(game)
  local snapshot = game:snapshot()
  return {
    schema = FieldSave.SCHEMA,
    versionId = "heartgold",
    mapId = snapshot.mapId,
    fieldX = snapshot.player.fieldX,
    fieldZ = snapshot.player.fieldZ,
    worldY = snapshot.player.worldY,
    surfaceId = snapshot.player.surfaceId,
    terrainDependencyHash = game.runtime.runtimeMap.terrainDependencyHash,
    facing = snapshot.player.facing,
    avatar = snapshot.avatarId,
    scenario = FieldScenarioManifest.id,
    world = game.runtime.scripts.worldState:capture(),
    scripts = ScriptSave.capture(game.runtime.scripts.scheduler, snapshot.tick, {
      registryFingerprint = game.runtime.scripts:registryFingerprint(),
    }),
    auxiliaryUi = { requested = "shown", state = "shown" },
    playerData = game.runtime.playerData,
  }
end

-- Plant a mutated session record at the live save path and boot a resume
-- through the production resume boundary, both runtimes sharing one isolated
-- namespace. The first runtime must stay alive until the resume boot reads
-- the planted file (its disposal save would overwrite it). Both runtimes are
-- returned; the caller asserts the resume outcome and closes them in
-- acquisition order. On a planting/boot failure the first runtime is closed
-- before rethrowing so the render trap cannot stay installed.
local function plantAndResume(mutate, namespace)
  local harness = AcceptanceHarness.new({
    saveNamespace = function()
      return namespace
    end,
  })
  local first = harness:boot({ versionId = "heartgold", map = TOWN, save = "fresh" })
  local resumed
  local ok, err = xpcall(function()
    local record = currentSessionRecord(first)
    mutate(record)
    love.filesystem.createDirectory("acceptance")
    love.filesystem.createDirectory("acceptance/player-data")
    love.filesystem.createDirectory(namespace)
    local written = love.filesystem.write(namespace .. "/" .. FieldSave.PATH, LuaWriter.encode(record))
    Assert.isTrue(written, "the planted save record must be written into the acceptance namespace")
    resumed = harness:boot({ versionId = "heartgold", map = TOWN, save = "resume" })
  end, debug.traceback)
  if not ok then
    if resumed then
      resumed:close()
    end
    first:close()
    error(err, 0)
  end
  return first, resumed
end

-- Plant a mutated record and assert the resume boundary rejects it with the
-- structured error: rejection assertions run inside a guarded body so any
-- failure still closes both runtimes in order.
local function resumePlantedRecord(mutate, expectedCode)
  local first, resumed = plantAndResume(mutate, "acceptance/player-data/planted")
  local ok, err = xpcall(function()
    assert(resumed.saveStatus, "the resume boot must report a save status")
    Assert.isTrue(
      resumed.saveStatus:find("Save ignored:", 1, true) ~= nil,
      "the planted record must be rejected at the resume boundary, got: " .. tostring(resumed.saveStatus)
    )
    Assert.isTrue(
      resumed.saveStatus:find(expectedCode, 1, true) ~= nil,
      "the rejection must carry the structured " .. expectedCode .. " error, got: " .. tostring(resumed.saveStatus)
    )
    Assert.equal(resumed:renderAttempts(), 0)
  end, debug.traceback)
  resumed:close()
  first:close()
  if not ok then
    error(err, 0)
  end
  return resumed
end

-- The current save schema REQUIRES the player-data bucket. A record
-- that is valid in every other bucket but omits it must be rejected with the
-- structured player-data error -- never accepted, defaulted, or upgraded.
function T.tests.current_schema_save_missing_the_player_data_bucket_is_rejected()
  resumePlantedRecord(function(record)
    record.playerData = nil
  end, "FIELD_SAVE_PLAYER_DATA_INVALID")
end

-- An arbitrary empty player-data bucket must never pass strict validation:
-- the resume boundary always supplies the player-data validation context
-- (the generated charmap and frame-index set), so a current-schema record
-- whose bucket is a bare table is rejected with the structured error. There
-- is no public path where a record with unvalidated player data resumes.
function T.tests.current_schema_save_with_arbitrary_player_data_is_rejected()
  resumePlantedRecord(function(record)
    record.playerData = {}
  end, "FIELD_SAVE_PLAYER_DATA_INVALID")
end

-- A player name containing a real multibyte field-font glyph: É (U+00C9) is
-- a two-byte UTF-8 sequence present in the generated charmap (glyph 360), so
-- "Élise" is a five-glyph name every glyph of which the generated field font
-- can encode. Validation must count and encode glyphs, never bytes: the
-- planted current-schema record must resume successfully and the resumed
-- profile must round-trip the exact name to the trainer card presentation
-- through production composition (the shared text path of the card viewer).
local MULTIBYTE_NAME = "Élise"

local function hostStatus(game)
  local host = game.runtime.applicationHost
  ---@diagnostic disable-next-line: undefined-field -- the runtime application-host surface is the contract under test
  return host:status()
end

-- The menu-key open edge through the production input pipeline: press, one
-- fixed tick, release.
local function pressMenuEdge(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
end

local function advanceToPhase(game, phase, maxTicks)
  return game:advanceUntil("start menu reaches " .. phase, function()
    return hostStatus(game).phase == phase
  end, maxTicks)
end

function T.tests.multibyte_player_name_validates_and_reaches_the_trainer_card_presentation()
  local first, resumed = plantAndResume(function(record)
    record.playerData = {
      profile = {
        name = MULTIBYTE_NAME,
        gender = record.playerData.profile.gender,
        trainerId = record.playerData.profile.trainerId,
      },
      options = {
        textFrame = record.playerData.options.textFrame,
        textSpeed = record.playerData.options.textSpeed,
      },
    }
  end, "acceptance/player-data/multibyte")
  local ok, err = xpcall(function()
    local profile = first.runtime.playerData.profile
    Assert.equal(resumed.saveStatus, "Resumed saved field session")
    Assert.equal(
      resumed.runtime.scripts.player:name(),
      MULTIBYTE_NAME,
      "the resumed profile must carry the multibyte player name"
    )
    local resumedProfile = resumed.runtime.playerData.profile
    Assert.equal(resumedProfile.gender, profile.gender, "the multibyte name must not disturb the profile gender")
    Assert.equal(
      resumedProfile.trainerId,
      profile.trainerId,
      "the multibyte name must not disturb the profile trainer id"
    )

    -- The trainer card viewer renders the player name through the shared
    -- field-text path, so the multibyte name must reach the card
    -- presentation through the production application composition. The
    -- trainer_card action is interactive only with its unlock flag set (the
    -- fresh planted save never earned it), so the journey unlocks the card
    -- explicitly before opening the menu.
    resumed:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    pressMenuEdge(resumed)
    advanceToPhase(resumed, "menu", 16)
    local actions = hostStatus(resumed).menu.actions
    Assert.equal(#actions, 1, "the resumed field must keep the trainer card action available")
    resumed.runtime:pressAction()
    resumed:step()
    resumed.runtime:releaseAction()
    advanceToPhase(resumed, "application", 64)
    local application = hostStatus(resumed).application
    Assert.isTrue(
      type(application) == "table",
      "the host snapshot must present the active card application, got: " .. tostring(application)
    )
    Assert.equal(
      application.name,
      MULTIBYTE_NAME,
      "the card presentation must carry the multibyte player name, got: " .. tostring(application and application.name)
    )
    Assert.equal(resumed:renderAttempts(), 0, "the multibyte card journey must not render")
  end, debug.traceback)
  resumed:close()
  first:close()
  if not ok then
    error(err, 0)
  end
end

-- The save schema moves forward with the player-data bucket; a
-- record at the previous current schema is an old save and fails with the
-- structured unsupported-schema error rather than loading or upgrading.
function T.tests.previous_schema_save_is_rejected_as_unsupported()
  resumePlantedRecord(function(record)
    record.schema = "g4-field-save-v2"
  end, "FIELD_SAVE_SCHEMA_UNSUPPORTED")
end

return T
