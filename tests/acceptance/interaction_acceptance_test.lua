-- Production-composed interaction, dialogue, and script contracts. These
-- scenarios drive real FieldRuntime input through AcceptanceHarness and stop
-- before presentation; no field service is assembled by the test.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "interaction", "dialogue", "script" },
  },
  tests = {},
}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN = "MAP_NEW_BARK"

local function requireGameCapability(game, name)
  Assert.isTrue(
    type(game[name]) == "function",
    "acceptance harness must expose " .. name .. " for production interaction"
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

local function interactAt(game, cell, facing)
  requireGameCapability(game, "moveTo")
  requireGameCapability(game, "face")
  requireGameCapability(game, "pressAction")
  game:moveTo(cell)
  game:face(facing)
  game:pressAction()
end

local function waitForDialogue(game)
  requireGameCapability(game, "advanceUntil")
  return game:advanceUntil("interaction opens dialogue", function(snapshot)
    return snapshot.dialogue.modal
  end, 120)
end

local function completeDialogue(game)
  requireGameCapability(game, "advanceDialogue")
  game:advanceDialogue()
  return game:advanceUntil("interaction releases field control", function(snapshot)
    return not snapshot.dialogue.modal and not snapshot.fieldLocked
  end, 480)
end

-- INT-01: the real resolver must retain object priority when the action cell
-- has both object and background candidates; the selected semantic target is
-- observable through the runtime, not a separately constructed resolver.
function T.tests.object_interaction_wins_over_a_background_candidate()
  withGame(LAB, function(game)
    requireGameCapability(game, "interaction")
    interactAt(game, { fieldX = 6, fieldZ = 6 }, "north")
    local interaction = game:interaction()
    Assert.equal(interaction.kind, "object")
    Assert.equal(interaction.actorId, "map:61:object:0")
  end)
end

-- INT-02: the healing-PC event is a real background event. Its public script
-- id, rather than copied message text, is the acceptance-visible contract.
function T.tests.background_interaction_starts_its_real_script_resource()
  withGame(LAB, function(game)
    requireGameCapability(game, "interaction")
    interactAt(game, { fieldX = 4, fieldZ = 4 }, "north")
    local interaction = game:interaction()
    Assert.equal(interaction.kind, "background")
    Assert.equal(interaction.scriptId, "vanilla.hgss.scr_seq.0843.script_013")
  end)
end

-- INT-03: the New Bark woman's bound vanilla script owns field input, faces
-- its actor, opens its real message, and releases all ownership on completion.
function T.tests.new_bark_woman_bound_script_restores_field_control()
  withGame(TOWN, function(game)
    requireGameCapability(game, "interaction")
    interactAt(game, { fieldX = 683, fieldZ = 400 }, "north")
    local interaction = game:interaction()
    Assert.equal(interaction.scriptId, "new_bark.npc.woman_1")
    local opened = waitForDialogue(game)
    Assert.isTrue(opened.fieldLocked)
    Assert.equal(opened.dialogue.messageId, 9)
    Assert.equal(game:interaction().actorFacing, "south")
    completeDialogue(game)
    Assert.isNil(game:interaction().actorFacingOverride)
  end)
end

-- INT-04: Elm's fresh-save conversation must follow the bound production
-- script scheduler, not the legacy pre-script preview fixture.
function T.tests.elm_fresh_save_conversation_runs_through_bound_script_scheduler()
  withGame(LAB, function(game)
    interactAt(game, { fieldX = 6, fieldZ = 6 }, "north")
    requireGameCapability(game, "interaction")
    Assert.equal(game:interaction().scriptId, "elms_lab.elm")
    local opened = waitForDialogue(game)
    Assert.isTrue(opened.fieldLocked)
    completeDialogue(game)
  end)
end

-- INT-05: a checked-in override must be observable as the selected source
-- layer while still executing through the same generated-script registry.
function T.tests.checked_in_override_composes_and_runs_to_completion()
  withGame(LAB, function(game)
    interactAt(game, { fieldX = 6, fieldZ = 6 }, "north")
    requireGameCapability(game, "interaction")
    Assert.equal(game:interaction().scriptSource, "override")
    waitForDialogue(game)
    completeDialogue(game)
  end)
end

-- INT-06: intentionally unbound supported events use the production fallback
-- adapter, including terminal cleanup of its temporary face-player override.
function T.tests.unbound_supported_interaction_uses_fallback_and_releases_override()
  withGame(LAB, function(game)
    interactAt(game, { fieldX = 9, fieldZ = 11 }, "south")
    requireGameCapability(game, "interaction")
    Assert.equal(game:interaction().owner, "pre-script-dialogue")
    waitForDialogue(game)
    completeDialogue(game)
    Assert.isNil(game:interaction().actorFacingOverride)
  end)
end

-- INT-07: dialogue/script ownership must reject movement until the modal path
-- completes; input edges may not leak into FieldPlayer while locked.
function T.tests.modal_owners_prevent_movement_until_completion()
  withGame(LAB, function(game)
    interactAt(game, { fieldX = 6, fieldZ = 6 }, "north")
    waitForDialogue(game)
    local before = game:snapshot().player
    game:move("south")
    local after = game:snapshot().player
    Assert.deepEqual({ after.fieldX, after.fieldZ }, { before.fieldX, before.fieldZ })
    completeDialogue(game)
  end)
end

-- INT-08: confirm drives controller state (reveal/page/close) through the
-- harness helper, never by an arbitrary number of fixed updates.
function T.tests.confirm_edges_progress_dialogue_to_close()
  withGame(TOWN, function(game)
    interactAt(game, { fieldX = 683, fieldZ = 400 }, "north")
    waitForDialogue(game)
    requireGameCapability(game, "advanceDialogue")
    local result = game:advanceDialogue()
    Assert.isTrue(result.confirmed)
    completeDialogue(game)
  end)
end

-- INT-09: the real script flow reaches its injected audio boundary. Field
-- locking and actor facing are runtime state, not host effects to fabricate.
function T.tests.script_audio_effect_is_recorded()
  withGame(TOWN, function(game)
    interactAt(game, { fieldX = 683, fieldZ = 400 }, "north")
    requireGameCapability(game, "hostEffects")
    waitForDialogue(game)
    completeDialogue(game)
    Assert.deepEqual(game:hostEffects(), {
      "audio:SEQ_SE_DP_SELECT",
    })
  end)
end

-- INT-10: fault injection is scoped to the foreground script boundary. A
-- failed script must leave no modal, lock, facing override, or live scheduler.
function T.tests.failing_foreground_script_releases_every_interaction_owner()
  withGame(LAB, function(game)
    requireGameCapability(game, "failForegroundScript")
    local result = game:failForegroundScript("elms_lab.elm")
    Assert.isTrue(result.error:find("elms_lab.elm", 1, true) ~= nil)
    local snapshot = game:snapshot()
    Assert.isFalse(snapshot.dialogue.modal)
    Assert.isFalse(snapshot.fieldLocked)
    Assert.isNil(game:interaction().actorFacingOverride)
  end)
end

return T
