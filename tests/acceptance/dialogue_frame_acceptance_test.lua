-- Production-composed dialogue frame-option contracts: the dialogue
-- presentation must carry the player-selected HGSS user-frame index,
-- resolved from the authoritative player data when the dialogue opens. A
-- fresh session derives it from the checked-in initial manifest; a resumed
-- session derives it from the required saved player-data bucket. Changing
-- the saved frame option changes the resolved frame while the message
-- content and flow stay identical. The renderer-facing status is the
-- surface observed here; the frame artwork itself is graphics-layer.

local Assert = require("tests.support.Assert")
local LuaWriter = require("libs.codec.src.LuaWriter")
local FieldSave = require("libs.engine.src.FieldSave")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "dialogue", "presentation", "options", "persistence" },
  },
  tests = {},
}

local TOWN = "MAP_NEW_BARK"
local WOMAN = { fieldX = 683, fieldZ = 400 }
-- The New Bark woman's default bound conversation (bank 542 message 9) is
-- the dialogue this scenario drives; the frame option must not change which
-- message opens.
local WOMAN_MESSAGE = 9

local function requireCapability(game, name)
  Assert.isTrue(
    type(game[name]) == "function",
    "acceptance harness must expose " .. name .. " for production dialogue-frame flows"
  )
end

local function openWomanDialogue(game)
  requireCapability(game, "moveTo")
  requireCapability(game, "face")
  requireCapability(game, "pressAction")
  requireCapability(game, "advanceUntil")
  game:moveTo(WOMAN)
  game:face("north")
  game:pressAction()
  return game:advanceUntil("interaction opens dialogue", function(snapshot)
    return snapshot.dialogue.modal
  end, 120)
end

local function completeDialogue(game)
  requireCapability(game, "advanceDialogue")
  game:advanceDialogue()
  return game:advanceUntil("interaction releases field control", function(snapshot)
    return not snapshot.dialogue.modal and not snapshot.fieldLocked
  end, 480)
end

-- A current-schema session record built from the production runtime's own
-- buckets (world capture, scripts capture, player data), so the planted
-- record validates in every bucket except the one the scenario mutates.
local function sessionRecord(game)
  local snapshot = game:snapshot()
  return {
    schema = FieldSave.SCHEMA,
    versionId = game.versionId,
    mapId = snapshot.mapId,
    fieldX = snapshot.player.fieldX,
    fieldZ = snapshot.player.fieldZ,
    worldY = snapshot.player.worldY,
    surfaceId = snapshot.player.surfaceId,
    terrainDependencyHash = game.runtime.runtimeMap.terrainDependencyHash,
    facing = snapshot.player.facing,
    avatar = snapshot.avatarId,
    world = game.runtime.scripts.worldState:capture(),
    scripts = ScriptSave.capture(game.runtime.scripts.scheduler, snapshot.tick, {
      registryFingerprint = game.runtime.scripts:registryFingerprint(),
    }),
    auxiliaryUi = { requested = "shown", state = "shown" },
    playerData = game.runtime.playerData,
  }
end

-- The open dialogue's presentation status must carry the player-selected
-- frame index, and the frame must follow the player-data authority across
-- the production save round trip: a fresh session resolves the initial
-- manifest frame, a resumed session with a different saved frame resolves
-- that saved frame, and the message content is identical both times.
function T.tests.open_dialogue_presentation_carries_the_player_selected_frame_index()
  local namespace = "acceptance/dialogue-frame/planted"
  local harness = AcceptanceHarness.new({
    saveNamespace = function()
      return namespace
    end,
  })
  local first = harness:boot({ versionId = AcceptanceHarness.defaultVersion(), map = TOWN, save = "fresh" })
  local resumed
  local ok, err = xpcall(function()
    local defaultFrame = first.runtime.playerData.options.textFrame
    Assert.equal(type(defaultFrame), "number", "the authoritative player data must expose a frame index")

    local opened = openWomanDialogue(first)
    Assert.equal(opened.dialogue.messageId, WOMAN_MESSAGE)
    Assert.equal(
      opened.dialogue.frameIndex,
      defaultFrame,
      "the open dialogue must carry the player-selected frame index on its presentation status, got: "
        .. tostring(opened.dialogue.frameIndex)
    )
    completeDialogue(first)
    Assert.equal(first:renderAttempts(), 0)

    -- The saved player-data bucket carries a different valid frame; the
    -- planted record must survive the resume boundary (which validates the
    -- frame against the generated frame set) and drive the reopened dialogue.
    local otherFrame = defaultFrame == 0 and 1 or 0
    local record = sessionRecord(first)
    record.playerData.options.textFrame = otherFrame
    love.filesystem.createDirectory("acceptance")
    love.filesystem.createDirectory("acceptance/dialogue-frame")
    love.filesystem.createDirectory(namespace)
    local written = love.filesystem.write(namespace .. "/" .. FieldSave.PATH, LuaWriter.encode(record))
    Assert.isTrue(written, "the planted save record must be written into the acceptance namespace")

    resumed = harness:boot({ versionId = AcceptanceHarness.defaultVersion(), map = TOWN, save = "resume" })
    assert(resumed.saveStatus, "the resume boot must report a save status")
    Assert.equal(resumed.saveStatus, "Resumed saved field session")
    Assert.equal(
      resumed.runtime.playerData.options.textFrame,
      otherFrame,
      "the resume boundary must restore the saved frame option"
    )

    local reopened = openWomanDialogue(resumed)
    Assert.equal(reopened.dialogue.messageId, WOMAN_MESSAGE)
    Assert.equal(
      reopened.dialogue.frameIndex,
      otherFrame,
      "the reopened dialogue must carry the saved frame index on its presentation status, got: "
        .. tostring(reopened.dialogue.frameIndex)
    )
    Assert.isTrue(
      reopened.dialogue.frameIndex ~= defaultFrame,
      "the frame index must change with the player's frame option"
    )
    completeDialogue(resumed)
    Assert.equal(resumed:renderAttempts(), 0)
  end, debug.traceback)
  if resumed then
    resumed:close()
  end
  first:close()
  if not ok then
    error(err, 0)
  end
end

return T
