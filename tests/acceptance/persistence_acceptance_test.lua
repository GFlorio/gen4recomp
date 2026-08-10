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

local function requireCapability(value, name)
  Assert.isTrue(
    type(value[name]) == "function",
    "acceptance harness must expose " .. name .. " for production persistence"
  )
end

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", map = LAB, save = "fresh" })
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

return T
