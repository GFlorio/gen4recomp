-- Production-composed contracts for source opcodes 55-60 through the real
-- classification/lowering/schema/runtime/host/task path. The two real New
-- Bark sign scripts (scr_seq member 842, message bank 542) start with the
-- signpost opcodes: script 14 is DirectionSignpostEx (55 at entry), script
-- 13 is TrainerTipsEx (56 at entry). 55 must present the signpost window
-- immediately and print its message instantly without writing its unused
-- result operand; 56 must only queue SHOW. Opcode 57 (SetSignpostAction)
-- then runs exactly one scheduler tick later, stores its raw source command
-- (WIPE_IN, operand 3) without executing it, and yields one tick. Opcode 58
-- (WaitSignpostAction) runs one tick later while the command is still busy
-- and blocks until the fixed-tick wipe completes and the command returns to
-- nop. Opcode 59 (TrainerTips) types its message into the existing signpost
-- window at the player text speed and completes only through the scheduler
-- result reference: 2 on normal completion, 0 on a directional interrupt
-- (which stops the printer and turns the player); A/B during the print is
-- the printer's speed-up behavior, never a dismissal. Opcode 60
-- (WaitSignpost) always installs a waiter and completes on A/B (result 0,
-- window closed) or a direction (result 0, window closed, player turned);
-- touch and mouse map to the semantic A edge. After the signpost opcode
-- completes, both scripts resume into the real common.signpost child script
-- (std_signpost): the child copies the special result, branches on it, and
-- for results 0/2 queues WIPE_OUT and signals the caller, so the whole
-- cleanup runs from the actual ROM-derived script material with zero script
-- faults. Rendering stays trapped.

local Assert = require("tests.support.Assert")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "signpost", "hgss" },
  },
  tests = {},
}

local DIRECTION_SIGNPOST = "vanilla.hgss.scr_seq.0842.script_014"
local SET_SIGNPOST_MAP = "vanilla.hgss.scr_seq.0842.script_013"

-- The result operand of opcodes 55/59/60 (VAR_SPECIAL_RESULT, 0x800C): 55
-- never writes it, 59/60 write their completion value through the scheduler
-- result reference.
local SPECIAL_RESULT = FieldScriptSymbols.variablesByName.VAR_SPECIAL_RESULT

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", map = "MAP_NEW_BARK", save = "fresh" })
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
      faults[#faults + 1] = {
        scriptId = record.payload.scriptId,
        code = record.payload.code,
        command = record.payload.context and record.payload.context.command,
      }
    end
  end
  return faults
end

local function signpostStatus(game)
  return game.runtime.signpost:status()
end

-- The imported script keeps the low-level nodes: the high-level sign
-- operations never rewrite the imported sequence (a walk over the compiled
-- effective graph, no high-level op anywhere).
local function assertNoHighLevelSignOps(game, scriptId, label)
  local composed = assert(game.runtime.scripts.composition:effective(scriptId))
  local graph = assert(composed.entries[1].graph, label .. " must compile to an executable graph")
  local count = 0
  for _, node in pairs(graph.nodes) do
    Assert.isTrue(node.op ~= "sign", label .. " must keep the low-level signpost nodes")
    Assert.isTrue(node.op ~= "trainer_tip", label .. " must keep the low-level signpost nodes")
    count = count + 1
  end
  Assert.isTrue(count > 0, label .. " compiled graph must have nodes")
end

local function faultCode(faults)
  return faults[1] and faults[1].code or "none"
end

-- The post-signpost tail of both real scripts: after the 59/60 completion
-- the script resumes into the real common.signpost child (std_signpost),
-- which copies the special result, branches on it, and for results 0/2
-- queues WIPE_OUT and signals the caller. Only the real child script can
-- set the wipe_out command, so observing it (with zero faults) proves the
-- collapsed call is gone and the actual cleanup material runs end to end.
local function assertStdSignpostWipeOut(game, label)
  game:advanceUntil(label .. ": the real std_signpost must queue its wipe-out", function()
    return #scriptFaults(game) >= 1 or signpostStatus(game).command == "wipe_out"
  end, 16)
  Assert.equal(
    #scriptFaults(game),
    0,
    label .. ": the real std_signpost must run without faulting, got: " .. faultCode(scriptFaults(game))
  )
  -- The wipe is real fixed-tick motion (one 16px step per scheduler tick
  -- through the production advanceAsync wiring), not an instant close.
  game:step()
  Assert.equal(signpostStatus(game).logicalYOffset, -16, label .. ": the wipe-out must move one 16px step per tick")
  game:advanceUntil(label .. ": the std_signpost wipe-out must complete", function()
    local status = signpostStatus(game)
    return status.command == "nop" and status.logicalYOffset == 0
  end, 16)
  Assert.equal(
    #scriptFaults(game),
    0,
    label .. ": the std_signpost wipe-out must complete without faulting, got: " .. faultCode(scriptFaults(game))
  )
  Assert.isFalse(signpostStatus(game).active, label .. ": the signpost must stay closed after the cleanup")
end

-- Walk the stable, previously pinned journey of the direction-signpost script (55 at
-- entry) through opcode 58's block and the wipe end, ending on the tick
-- where the command is nop. The caller then steps into opcode 60.
local function advanceDirectionSignpostThroughWipe(game)
  local status = signpostStatus(game)
  Assert.isTrue(status.active, "opcode 55 must present the signpost window immediately")
  Assert.equal(status.command, "nop")
  Assert.isTrue(status.printDone, "opcode 55 must print its message instantly")
  game:step()
  local afterAction = signpostStatus(game)
  Assert.equal(#scriptFaults(game), 0, "the script must not fault at opcode 57, got: " .. faultCode(scriptFaults(game)))
  Assert.equal(
    afterAction.command,
    "wipe_in",
    "opcode 57 must queue its source command one tick after opcode 55, got: " .. tostring(afterAction.command)
  )
  Assert.equal(afterAction.logicalYOffset, -48, "opcode 57 must not execute its queued command")
  game:step()
  local afterWait = signpostStatus(game)
  Assert.equal(
    #scriptFaults(game),
    0,
    "opcode 58 must block while the command is busy, got: " .. faultCode(scriptFaults(game))
  )
  Assert.equal(afterWait.command, "wipe_in", "the wipe must still be in motion while the wait is active")
  Assert.equal(afterWait.logicalYOffset, -32, "the signpost controller must advance once per scheduler tick")
  game:advanceUntil("the signpost command returns to nop", function()
    return signpostStatus(game).command == "nop"
  end, 8)
  Assert.equal(#scriptFaults(game), 0, "the wait must not complete before the signpost command is nop")
end

-- The same journey for the TrainerTipsEx script (56 at entry), through the
-- queued SHOW, opcode 57's queued wipe, opcode 58's block, and the wipe
-- end. The caller then steps into opcode 59.
local function advanceSetSignpostMapThroughWipe(game)
  local status = signpostStatus(game)
  Assert.isFalse(status.active, "opcode 56 must not execute SHOW immediately")
  Assert.equal(status.command, "show")
  game:step()
  local afterAction = signpostStatus(game)
  Assert.equal(#scriptFaults(game), 0, "the script must not fault at opcode 57, got: " .. faultCode(scriptFaults(game)))
  Assert.isTrue(afterAction.active, "the queued SHOW must run at the next field update")
  Assert.equal(
    afterAction.command,
    "wipe_in",
    "opcode 57 must queue its source command one tick after opcode 56, got: " .. tostring(afterAction.command)
  )
  Assert.equal(afterAction.logicalYOffset, -48, "opcode 57 must not execute its queued command")
  game:step()
  local afterWait = signpostStatus(game)
  Assert.equal(
    #scriptFaults(game),
    0,
    "opcode 58 must block while the command is busy, got: " .. faultCode(scriptFaults(game))
  )
  Assert.equal(afterWait.command, "wipe_in", "the wipe must still be in motion while the wait is active")
  Assert.equal(afterWait.logicalYOffset, -32, "the signpost controller must advance once per scheduler tick")
  game:advanceUntil("the signpost command returns to nop", function()
    return signpostStatus(game).command == "nop"
  end, 8)
  Assert.equal(#scriptFaults(game), 0, "the wait must not complete before the signpost command is nop")
end

-- The real New Bark town direction sign (DirectionSignpostEx): opcode 55
-- selects SHOW, executes it immediately, expands its message and prints it
-- instantly, yields exactly one tick, and never writes the unused out
-- operand. Opcode 57 queues WIPE_IN without executing it, opcode 58 blocks
-- until the wipe completes, and opcode 60 then waits for dismissal: A (the
-- semantic edge touch and mouse map to) dismisses with result 0 and closes
-- the window, and the script resumes into the real std_signpost child,
-- whose wipe-out cleanup ends the flow without a script fault.
function T.tests.direction_signpost_shows_immediately_yields_once_and_never_writes_its_out_operand()
  withGame(function(game)
    assertNoHighLevelSignOps(game, DIRECTION_SIGNPOST, "the direction-signpost override")
    game:setWorldState({ variable = SPECIAL_RESULT, value = 77 })
    game:startScript(DIRECTION_SIGNPOST)

    local faults = scriptFaults(game)
    Assert.equal(#faults, 0, "the direction-signpost script must not fault at opcode 55, got: " .. faultCode(faults))

    -- 55 executes SHOW immediately: the window is presented (command
    -- already back to nop) and the message is printed instantly, with the
    -- real ROM type/map operands preserved as source appearance.
    local status = signpostStatus(game)
    Assert.isTrue(status.active, "opcode 55 must present the signpost window immediately")
    Assert.equal(status.command, "nop")
    Assert.deepEqual(status.sourceAppearance, { game = "hgss", type = 0, map = 11 })
    Assert.isTrue(#status.visibleLines > 0, "opcode 55 must print its message instantly")
    Assert.isTrue(status.printDone, "the instant signpost print must be complete")

    -- The unused result operand is never written: the sentinel survives
    -- opcode 55 and the whole wipe journey (57 queues WIPE_IN one tick
    -- later without executing it, 58 blocks until the wipe returns the
    -- command to nop).
    Assert.equal(game.runtime.scripts.worldState:getVar(SPECIAL_RESULT), 77)
    advanceDirectionSignpostThroughWipe(game)
    Assert.equal(game.runtime.scripts.worldState:getVar(SPECIAL_RESULT), 77)

    -- The waiter completes only after the wipe reaches its endpoint and
    -- the command returns to nop; the script resumes on the following
    -- scheduler tick, where opcode 60 installs its own waiter instead of
    -- faulting.
    game:step()
    local afterSignpost = scriptFaults(game)
    Assert.equal(
      #afterSignpost,
      0,
      "opcode 60 must not fault: WaitSignpost installs a waiter, got: " .. faultCode(afterSignpost)
    )
    Assert.isTrue(signpostStatus(game).active, "the signpost stays presented while WaitSignpost waits")

    -- A dismisses the signpost (the semantic edge touch and mouse map to):
    -- result 0, the window closes, and the script resumes into the real
    -- std_signpost cleanup on the following tick.
    game:pressAction()
    Assert.isFalse(signpostStatus(game).active, "A must dismiss the signpost window (textbox_open = false)")
    Assert.equal(signpostStatus(game).command, "nop")
    local dismissed = scriptFaults(game)
    Assert.equal(#dismissed, 0, "the dismissal itself must not fault, got: " .. faultCode(dismissed))
    assertStdSignpostWipeOut(game, "direction sign A dismissal")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      0,
      "opcode 60 must write its dismissal result 0"
    )
  end)
end

-- The real New Bark TrainerTipsEx script: opcode 56 writes the source
-- appearance and queues SHOW without executing it, prints nothing, and
-- yields exactly one tick; the queued SHOW runs at the next tick's field
-- update. Opcode 57 then queues WIPE_IN and yields, opcode 58 blocks until
-- the wipe completes, and opcode 59 types its message into the signpost
-- window at the player text speed: normal completion writes 2 and leaves
-- the window open, after which the script resumes into the real
-- std_signpost child, whose own WaitSignpost keeps the window open until a
-- dismissal input and then wipes the sign out.
function T.tests.set_signpost_map_queues_show_and_yields_once()
  withGame(function(game)
    game:startScript(SET_SIGNPOST_MAP)

    local faults = scriptFaults(game)
    Assert.equal(#faults, 0, "the set-signpost-map script must not fault at opcode 56, got: " .. faultCode(faults))

    -- 56 queues SHOW: the command is stored but not executed, the window
    -- is not presented, and no text is invented. The queued SHOW runs at
    -- the next tick's field update; 57 then queues WIPE_IN and yields, and
    -- 58 blocks until the wipe returns the command to nop.
    local status = signpostStatus(game)
    Assert.isFalse(status.active, "opcode 56 must not execute SHOW immediately")
    Assert.equal(status.command, "show")
    Assert.deepEqual(status.sourceAppearance, { game = "hgss", type = 2, map = 0 })
    Assert.deepEqual(status.visibleLines, {})
    Assert.isFalse(status.printDone)
    advanceSetSignpostMapThroughWipe(game)

    -- One tick past nop: opcode 59 types its message into the signpost
    -- window at the player text speed.
    game:step()
    local printing = scriptFaults(game)
    Assert.equal(
      #printing,
      0,
      "opcode 59 must not fault: TrainerTips starts a typed print, got: " .. faultCode(printing)
    )
    Assert.isFalse(signpostStatus(game).printDone, "opcode 59 must type at the player text speed, not instantly")
    Assert.isTrue(signpostStatus(game).active, "the signpost stays presented while Trainer Tips prints")

    -- The print completes at the fixed-tick cadence without any input;
    -- normal completion writes 2 (on the promotion tick) and leaves the
    -- window open.
    game:advanceUntil("the trainer tips print completes", function()
      return signpostStatus(game).printDone
    end, 64)
    Assert.equal(#scriptFaults(game), 0, "the print completion must not fault")

    -- The script resumes into the real std_signpost child, whose own
    -- WaitSignpost (opcode 60) keeps the window open until a dismissal.
    game:step()
    Assert.equal(
      #scriptFaults(game),
      0,
      "the std_signpost child must not fault, got: " .. faultCode(scriptFaults(game))
    )
    Assert.isTrue(signpostStatus(game).active, "the std_signpost child keeps the window open while it waits")
    game:step()
    Assert.equal(
      #scriptFaults(game),
      0,
      "the std_signpost child must not fault, got: " .. faultCode(scriptFaults(game))
    )
    Assert.isTrue(signpostStatus(game).active, "the std_signpost child keeps the window open while it waits")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      2,
      "opcode 59 must write its normal completion result 2"
    )

    -- A dismisses the child's wait: the child writes its own dismissal
    -- result 0 over the completion value and wipes the sign out.
    game:pressAction()
    assertStdSignpostWipeOut(game, "trainer tips normal completion")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      0,
      "the std_signpost WaitSignpost must write its dismissal result 0"
    )
  end)
end

-- A directional edge while WaitSignpost waits dismisses like A/B but also
-- turns the player to that direction before completing with result 0; the
-- real std_signpost cleanup then wipes the sign out.
function T.tests.wait_signpost_directional_dismissal_turns_the_player_and_writes_zero()
  withGame(function(game)
    game:startScript(DIRECTION_SIGNPOST)
    Assert.equal(#scriptFaults(game), 0, "the direction-signpost script must not fault at opcode 55")
    advanceDirectionSignpostThroughWipe(game)

    -- One tick past nop: opcode 60 installs its waiter instead of faulting.
    game:step()
    Assert.equal(
      #scriptFaults(game),
      0,
      "opcode 60 must not fault: WaitSignpost installs a waiter, got: " .. faultCode(scriptFaults(game))
    )
    Assert.isTrue(signpostStatus(game).active, "the signpost stays presented while WaitSignpost waits")

    -- A held-facing-independent direction: dismissal must turn the player
    -- to exactly the pressed direction.
    local before = game:snapshot().player.facing
    local pressed = before == "south" and "west" or "south"
    game:move(pressed)
    Assert.isFalse(signpostStatus(game).active, "a direction must dismiss the signpost window")
    Assert.equal(signpostStatus(game).command, "nop")
    Assert.equal(game:snapshot().player.facing, pressed, "a directional dismissal must turn the player")
    local dismissed = scriptFaults(game)
    Assert.equal(#dismissed, 0, "the dismissal itself must not fault, got: " .. faultCode(dismissed))

    assertStdSignpostWipeOut(game, "directional signpost dismissal")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      0,
      "opcode 60 must write its directional dismissal result 0"
    )
  end)
end

-- A directional edge pressed while the Trainer Tips print is still typing
-- stops the printer, turns the player, closes the window, and completes
-- with result 0 — the source directional-interruption path. The real
-- std_signpost cleanup then wipes the sign out.
function T.tests.trainer_tips_directional_interrupt_stops_the_print_turns_and_writes_zero()
  withGame(function(game)
    game:startScript(SET_SIGNPOST_MAP)
    Assert.equal(#scriptFaults(game), 0, "the set-signpost-map script must not fault at opcode 56")
    advanceSetSignpostMapThroughWipe(game)

    -- One tick past nop: opcode 59 starts its typed print instead of
    -- faulting.
    game:step()
    Assert.equal(
      #scriptFaults(game),
      0,
      "opcode 59 must not fault: TrainerTips starts a typed print, got: " .. faultCode(scriptFaults(game))
    )
    Assert.isFalse(signpostStatus(game).printDone, "opcode 59 must type at the player text speed, not instantly")
    Assert.isTrue(signpostStatus(game).active, "the signpost stays presented while Trainer Tips prints")

    -- Interrupt while the print is still typing.
    local before = game:snapshot().player.facing
    local pressed = before == "south" and "west" or "south"
    game:move(pressed)
    Assert.isFalse(signpostStatus(game).printDone, "the directional interrupt must stop the printer")
    Assert.isFalse(signpostStatus(game).active, "the directional interrupt must close the signpost window")
    Assert.equal(signpostStatus(game).command, "nop")
    Assert.equal(game:snapshot().player.facing, pressed, "the directional interrupt must turn the player")
    local interrupted = scriptFaults(game)
    Assert.equal(#interrupted, 0, "the interrupt itself must not fault, got: " .. faultCode(interrupted))

    assertStdSignpostWipeOut(game, "trainer tips directional interrupt")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      0,
      "opcode 59 must write its directional interrupt result 0"
    )
  end)
end

-- A/B during the Trainer Tips print is the text printer's speed-up
-- behavior, not a dismissal: pressing A mid-print must keep the signpost
-- window open and the script must still complete normally with result 2,
-- then the real std_signpost child waits for its own dismissal.
function T.tests.trainer_tips_a_during_print_is_not_a_dismissal()
  withGame(function(game)
    game:startScript(SET_SIGNPOST_MAP)
    Assert.equal(#scriptFaults(game), 0, "the set-signpost-map script must not fault at opcode 56")
    advanceSetSignpostMapThroughWipe(game)

    -- One tick past nop: opcode 59 starts its typed print instead of
    -- faulting.
    game:step()
    Assert.equal(
      #scriptFaults(game),
      0,
      "opcode 59 must not fault: TrainerTips starts a typed print, got: " .. faultCode(scriptFaults(game))
    )
    Assert.isFalse(signpostStatus(game).printDone, "opcode 59 must type at the player text speed, not instantly")

    -- A mid-print must not dismiss: the window stays open and the script
    -- still completes normally with result 2.
    game:pressAction()
    Assert.isTrue(signpostStatus(game).active, "A during the print must not dismiss the signpost")
    Assert.equal(signpostStatus(game).command, "nop")
    Assert.equal(#scriptFaults(game), 0, "A during the print must not fault, got: " .. faultCode(scriptFaults(game)))

    game:advanceUntil("the trainer tips print completes", function()
      return signpostStatus(game).printDone
    end, 64)
    Assert.equal(#scriptFaults(game), 0, "the print completion must not fault")

    -- The real std_signpost child then waits for its own dismissal and
    -- wipes the sign out.
    game:step()
    Assert.equal(
      #scriptFaults(game),
      0,
      "the std_signpost child must not fault, got: " .. faultCode(scriptFaults(game))
    )
    Assert.isTrue(signpostStatus(game).active, "the std_signpost child keeps the window open while it waits")
    game:step()
    Assert.equal(
      #scriptFaults(game),
      0,
      "the std_signpost child must not fault, got: " .. faultCode(scriptFaults(game))
    )
    Assert.isTrue(signpostStatus(game).active, "the std_signpost child keeps the window open while it waits")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      2,
      "A during the print must not change the normal completion result 2"
    )
    Assert.isTrue(signpostStatus(game).active, "the signpost window stays open after a button-speed-up completion")

    game:pressAction()
    assertStdSignpostWipeOut(game, "trainer tips button-speed-up completion")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      0,
      "the std_signpost WaitSignpost must write its dismissal result 0"
    )
  end)
end

return T
