-- Production-composed interaction, dialogue, and script contracts. These
-- scenarios drive real FieldRuntime input through AcceptanceHarness and stop
-- before presentation; no field service is assembled by the test.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
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
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = map,
    save = "fresh",
    fieldOptions = { recordingScriptHosts = true },
  })
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

-- The production fault surface: the scheduler emits script.error with full
-- attribution through the events host; the snapshot surface carries no
-- fault attribution. Ended roots are not archived, so the scenarios
-- read the recorded event stream through the harness's hosts handle.
local function scriptFaults(game)
  local faults = {}
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == "script.error" then
      faults[#faults + 1] = { scriptId = record.payload.scriptId, endReason = record.payload.code }
    end
  end
  return faults
end

-- Live scheduler ownership after a script ends: no running instance, no
-- live task record, no foreground environment owning the field.
local function liveSchedulerState(game)
  local scheduler = game.runtime.scripts.scheduler
  return {
    liveInstances = #scheduler:liveInstances(),
    tasks = #scheduler:tasks(),
    foregroundEnvironmentId = scheduler:foregroundEnvironmentId(),
  }
end

-- A faulting script contract: the script faults with the attributed code and
-- releases every interaction owner (no modal, no field lock, no live
-- scheduler state, no facing override).
local function assertFaultReleasedEverything(game, snapshot, scriptId, endReason)
  local faults = scriptFaults(game)
  local fault
  for index = #faults, 1, -1 do
    if faults[index].scriptId == scriptId then
      fault = faults[index]
      break
    end
  end
  fault = assert(fault, "the foreground script must fault")
  Assert.equal(fault.scriptId, scriptId)
  Assert.equal(fault.endReason, endReason)
  Assert.isFalse(snapshot.dialogue.modal)
  Assert.isFalse(snapshot.fieldLocked)
  local scheduler = liveSchedulerState(game)
  Assert.equal(scheduler.liveInstances, 0)
  Assert.equal(scheduler.tasks, 0)
  Assert.isNil(scheduler.foregroundEnvironmentId)
  Assert.isNil(game:interaction().actorFacingOverride)
end

local function completeDialogue(game)
  requireGameCapability(game, "advanceDialogue")
  game:advanceDialogue()
  return game:advanceUntil("interaction releases field control", function(snapshot)
    return not snapshot.dialogue.modal and not snapshot.fieldLocked
  end, 480)
end

-- INT-01/02: the real resolver retains object priority when the action cell
-- has both object and background candidates, and a background-only cell
-- resolves to its real script resource. Both selections are observable
-- through the runtime, not a separately constructed resolver.
function T.tests.object_and_background_interactions_resolve_through_the_real_resolver()
  withGame(LAB, function(game)
    requireGameCapability(game, "interaction")
    interactAt(game, { fieldX = 6, fieldZ = 6 }, "north")
    local object = game:interaction()
    Assert.equal(object.kind, "object")
    Assert.equal(object.actorId, "map:61:object:0")
    -- The elms conversation faults at its first unsupported node; wait for
    -- the field to release before walking to the background cell.
    game:advanceUntil("elms fault releases the field", function(snapshot)
      return not snapshot.dialogue.modal and not snapshot.fieldLocked
    end, 120)

    game:moveTo({ fieldX = 4, fieldZ = 4 })
    game:face("north")
    game:pressAction()
    local background = game:interaction()
    Assert.equal(background.kind, "background")
    Assert.equal(background.scriptId, "vanilla.hgss.scr_seq.0843.script_013")
  end)
end

-- INT-03/07/08/09: the New Bark woman's bound vanilla script owns field
-- input, faces its actor, opens its real message, rejects movement while
-- modal, progresses on confirm edges, records its injected audio effect, and
-- releases all ownership on completion.
function T.tests.new_bark_woman_bound_script_runs_its_full_dialogue_lifecycle()
  withGame(TOWN, function(game)
    requireGameCapability(game, "interaction")
    interactAt(game, { fieldX = 683, fieldZ = 400 }, "north")
    local interaction = game:interaction()
    Assert.equal(interaction.scriptId, "new_bark.npc.woman_1")
    local opened = waitForDialogue(game)
    Assert.isTrue(opened.fieldLocked)
    Assert.equal(opened.dialogue.messageId, 9)
    Assert.equal(game:interaction().actorFacing, "south")

    local before = game:snapshot().player
    game:move("south")
    local after = game:snapshot().player
    Assert.deepEqual({ after.fieldX, after.fieldZ }, { before.fieldX, before.fieldZ })

    requireGameCapability(game, "advanceDialogue")
    local result = game:advanceDialogue()
    Assert.isTrue(result.confirmed)
    completeDialogue(game)
    Assert.deepEqual(game:hostEffects(), {
      "audio:SEQ_SE_DP_SELECT",
    })
    Assert.isNil(game:interaction().actorFacingOverride)

    -- The terminal close clears the request and page state, so the
    -- presentation-facing status after completion carries no stale message
    -- identity for the renderer to keep showing.
    local closed = game:snapshot().dialogue
    Assert.equal(closed.state, "CLOSED")
    Assert.isNil(closed.requestId)
    Assert.isNil(closed.bankId)
    Assert.isNil(closed.messageId)
    Assert.equal(closed.pageCount, 0)

    -- The cleared terminal state must not break a reentrant open: a second
    -- interaction with the same NPC re-runs the same real message through
    -- production composition and closes cleanly again.
    interactAt(game, { fieldX = 683, fieldZ = 400 }, "north")
    local reopened = waitForDialogue(game)
    Assert.isTrue(reopened.dialogue.modal)
    Assert.equal(reopened.dialogue.messageId, 9)
    Assert.isTrue(reopened.fieldLocked)
    game:advanceDialogue()
    completeDialogue(game)
    local reclosed = game:snapshot().dialogue
    Assert.equal(reclosed.state, "CLOSED")
    Assert.isNil(reclosed.requestId)
    Assert.isNil(reclosed.messageId)
    Assert.equal(reclosed.pageCount, 0)

    -- Ended instances are pruned once nothing references them; the
    -- completed root (no observer) must not remain in the scheduler archive.
    Assert.equal(#game.runtime.scripts.scheduler:instances(), 0)
  end)
end

-- INT-05: a checked-in override must be observable as the selected source
-- layer while still executing through the same generated-script registry;
-- the override's first unsupported node faults with attribution instead of
-- composing into a working placeholder box.
function T.tests.checked_in_override_faults_at_its_first_unsupported_node()
  withGame(LAB, function(game)
    interactAt(game, { fieldX = 6, fieldZ = 6 }, "north")
    requireGameCapability(game, "interaction")
    Assert.equal(game:interaction().scriptId, "elms_lab.elm")
    Assert.equal(game:interaction().scriptSource, "override")
    -- The fresh-save conversation's first reachable node is an unsupported
    -- command (ScrCmd_GetPartyCount): the script faults instead of opening
    -- the placeholder box.
    local faulted = game:advanceUntil("composed override faults at its first unsupported node", function(snapshot)
      return not snapshot.dialogue.modal and not snapshot.fieldLocked
    end, 120)
    assertFaultReleasedEverything(game, faulted, "elms_lab.elm", "SCRIPT_UNSUPPORTED_REACHABLE")
  end)
end

return T
