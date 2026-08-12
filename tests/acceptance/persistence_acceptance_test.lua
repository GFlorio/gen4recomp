-- Production-composed persistence, lifecycle, and determinism contracts. The
-- shared harness must carry saves between non-rendering runtime boots; tests
-- never restore FieldSave or construct a field subsystem themselves.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "persistence", "lifecycle", "determinism" },
  },
  tests = {},
}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN = "MAP_NEW_BARK"

local function requireCapability(value, name)
  Assert.isTrue(
    type(value[name]) == "function",
    "acceptance harness must expose " .. name .. " for production persistence"
  )
end

local function withGame(map, fn)
  if fn == nil then
    fn = map
    map = LAB
  end
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

local function restart(game, options)
  requireCapability(game, "restart")
  return game:restart(options)
end

-- DET-02 helper: confirm edges like the harness's advanceDialogue, but stop
-- at the first mid-script boundary — no modal box open while the foreground
-- script still holds field control. One further tick lands on the live
-- wait_input task (the dialogue task completes one tick before the handoff
-- creates it), so the save captures the blocked instance with its live task
-- record.
local function confirmToMidScriptBoundary(game)
  for _ = 1, 480 do
    local snapshot = game:snapshot()
    if not snapshot.dialogue.modal then
      if snapshot.fieldLocked then
        game:step()
        local boundary = game:snapshot()
        assert(
          not boundary.dialogue.modal and boundary.fieldLocked,
          "mid-script boundary must hold field control with no modal box"
        )
        return boundary
      end
      error("foreground script released field control before a mid-script boundary", 2)
    end
    game:pressAction()
  end
  error("no mid-script boundary within 480 confirm edges", 2)
end

-- SAVE-01: disposal is the production save boundary. The replacement runtime
-- must observe exactly one valid record, rather than this test calling save.
function T.tests.disposing_the_field_runtime_saves_once_for_restart()
  withGame(function(game)
    local resumed = restart(game, { save = "resume" })
    Assert.equal(resumed.saveStatus, "Resumed saved field session")
    Assert.equal(resumed.lifecycle.saveWrites, 1)
  end)
end

-- SAVE-02: a process-like runtime restart restores durable player and world
-- facts through FieldRuntime's normal resume path.
function T.tests.restart_resumes_location_avatar_and_world_state()
  withGame(function(game)
    requireCapability(game, "setWorldState")
    game:moveTo({ fieldX = 6, fieldZ = 6 })
    game:face("north")
    game:setWorldState({ flag = 100, variable = 7, value = 7 })
    local before = game:snapshot()
    local resumed = restart(game, { save = "resume" })
    local after = resumed:snapshot()
    Assert.deepEqual(after.player, before.player)
    Assert.deepEqual(after.world, { flags = { [100] = true }, variables = { [7] = 7 } })
    Assert.notNil(after.avatarId)
  end)
end

-- SAVE-03: persisted scenario flags keep story-hidden actors absent; a
-- resumed boot must not run fresh-session seeding over the restored world.
function T.tests.resumed_world_state_does_not_revive_story_hidden_actors()
  withGame(function(game)
    local resumed = restart(game, { save = "resume" })
    requireCapability(resumed, "actor")
    Assert.isNil(resumed:actor("map:61:object:1"))
    Assert.isNil(resumed:actor("map:61:object:3"))
  end)
end

-- SAVE-04: a resume on the lab's door warp restores arrival suppression, so
-- one fixed tick cannot immediately transition the player back out.
function T.tests.restart_on_a_warp_cell_preserves_arrival_suppression()
  withGame(function(game)
    game:moveTo({ fieldX = 4, fieldZ = 14 })
    local resumed = restart(game, { save = "resume" })
    local before = resumed:snapshot()
    resumed:step()
    local after = resumed:snapshot()
    Assert.equal(after.mapId, before.mapId)
    Assert.equal(after.transition.phase, "idle")
  end)
end

-- SAVE-05: an explicit new session discards the prior isolated field save and
-- applies the fresh scenario exactly once through the normal boot path.
function T.tests.explicit_new_session_ignores_the_prior_field_save()
  withGame(function(game)
    game:moveTo({ fieldX = 6, fieldZ = 6 })
    local fresh = restart(game, { save = "fresh" })
    local snapshot = fresh:snapshot()
    Assert.deepEqual({ snapshot.player.fieldX, snapshot.player.fieldZ }, { 4, 13 })
    Assert.equal(fresh.saveStatus, "Started a new field session")
  end)
end

-- SAVE-06: a filesystem write failure must be visible at the runtime boundary
-- and must not turn a later close into a second save or false success.
function T.tests.failed_save_is_visible_without_double_disposal()
  withGame(function(game)
    requireCapability(game, "failNextSave")
    game:failNextSave()
    local result = restart(game, { save = "resume" })
    Assert.isTrue(result.saveStatus:find("Save failed:", 1, true) ~= nil)
    Assert.equal(result.lifecycle.saveWrites, 1)
    Assert.equal(result.lifecycle.runtimeDisposals, 1)
  end)
end

-- LIFE-01: actor removal responds to an event update at the same fixed-tick
-- boundary, including the occupancy view consumed by player movement.
function T.tests.event_driven_actor_removal_updates_visibility_and_occupancy_in_one_tick()
  withGame(function(game)
    requireCapability(game, "setActorRemovalFlag")
    game:setActorRemovalFlag("map:61:object:0")
    game:step()
    local snapshot = game:snapshot()
    Assert.isNil(snapshot.actors["map:61:object:0"])
    Assert.isNil(snapshot.occupancy["6:5"])
  end)
end

-- LIFE-02: replacing the live field application state and later quitting it
-- must save/dispose the old runtime exactly once through the app boundary.
function T.tests.application_replacement_and_quit_dispose_the_field_once()
  withGame(function(game)
    requireCapability(game, "replaceApplicationState")
    local result = game:replaceApplicationState()
    Assert.equal(result.replaced.lifecycle.saveWrites, 1)
    Assert.equal(result.replaced.lifecycle.runtimeDisposals, 1)
    Assert.equal(result.active.lifecycle.runtimeDisposals, 1)
  end)
end

-- DET-01: semantic inputs replayed from the same fresh state must produce the
-- same bounded stable trace, independent of incidental runtime object state.
function T.tests.semantic_input_replay_has_a_stable_runtime_trace()
  withGame(function(game)
    requireCapability(game, "replay")
    local inputs = { "east", "east", "south", "action", "north" }
    local first = game:replay(inputs, { save = "fresh" })
    local second = game:replay(inputs, { save = "fresh" })
    Assert.deepEqual(first.trace, second.trace)
    Assert.isTrue(#first.trace > 0)
  end)
end

-- DET-02: a save captured mid-script (the bound New Bark woman script
-- holding field control at its wait_input prompt, after its real message
-- closed) must restore through the recomputed revision path: the resumed
-- script resumes at its real prompt — there is no placeholder anymore —
-- and completes releasing field control.
function T.tests.mid_script_restart_resumes_through_recomputed_revisions()
  withGame(TOWN, function(game)
    requireCapability(game, "moveTo")
    requireCapability(game, "face")
    requireCapability(game, "pressAction")
    requireCapability(game, "interaction")
    requireCapability(game, "advanceUntil")
    game:moveTo({ fieldX = 683, fieldZ = 400 })
    game:face("north")
    game:pressAction()
    Assert.equal(game:interaction().scriptId, "new_bark.npc.woman_1")
    -- The fresh-save conversation opens its real first message
    -- (msg.hgss.0542.00009) through the bound script, not a placeholder.
    local opened = game:advanceUntil("woman script opens its real first message", function(snapshot)
      return snapshot.dialogue.modal
    end, 120)
    Assert.isTrue(opened.fieldLocked)
    Assert.equal(opened.dialogue.messageId, 9)
    -- The save boundary: after the first box closes the script still holds
    -- field control at its wait_input prompt.
    local boundary = confirmToMidScriptBoundary(game)
    Assert.isTrue(boundary.fieldLocked)
    Assert.isFalse(boundary.dialogue.modal)
    local resumed = restart(game, { save = "resume" })
    Assert.equal(resumed.saveStatus, "Resumed saved field session")
    -- Foreground environment restored: the live task record survives the
    -- restart through the recomputed-revision path.
    Assert.isTrue(resumed:snapshot().fieldLocked)
    -- The resumed script continues at its real wait_input prompt: no
    -- placeholder box reopens (there is no placeholder anymore), and the
    -- next confirm edge completes the flow and releases field control.
    Assert.isFalse(resumed:snapshot().dialogue.modal)
    resumed:pressAction()
    local done = resumed:advanceUntil("resumed script completes and releases field control", function(snapshot)
      return not snapshot.dialogue.modal and not snapshot.fieldLocked
    end, 480)
    Assert.isFalse(done.dialogue.modal)
    Assert.isFalse(done.fieldLocked)
  end)
end

return T
