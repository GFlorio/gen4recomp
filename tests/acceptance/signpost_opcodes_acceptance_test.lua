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
-- (which cuts off the print and turns the player); A/B during the print is
-- the instant-fill operation — the whole message reveals on the input tick,
-- the window stays visible, and the task still completes with the normal
-- print-complete result 2, with the direction preferred when it arrives on
-- the same live-print tick. Pointer/touch input never reaches the print
-- path. Opcode 60
-- (WaitSignpost) always installs a waiter and completes on A/B (result 0,
-- window closed) or a direction (result 0, window closed, player turned);
-- touch and mouse map to the semantic A edge. After the signpost opcode
-- completes, both scripts resume into the real common.signpost child script
-- (std_signpost): the child copies the special result, branches on it, and
-- for results 0/2 queues WIPE_OUT and signals the caller, so the whole
-- cleanup runs from the actual ROM-derived script material with zero script
-- faults. The child context ends at its signal_caller tail (opcode 21):
-- the source commands that follow the signal in the same script (the next
-- branch's wipe/hide) never run, and the executable semantic program keeps
-- signal_caller terminal with no linear continuation. The executable nodes
-- also carry no sourceUnusedOut (opcode 55's audited, unused result
-- operand), and a high-level sign opened after an imported signpost
-- dismissal must not inherit the imported source appearance. Rendering
-- stays trapped.

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
local DEMO_SIGNPOST = "demo.signpost"

-- The result operand of opcodes 55/59/60 (VAR_SPECIAL_RESULT, 0x800C): 55
-- never writes it, 59/60 write their completion value through the scheduler
-- result reference.
local SPECIAL_RESULT = FieldScriptSymbols.variablesByName.VAR_SPECIAL_RESULT

local function withGame(fn, fieldOptions)
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = fieldOptions,
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

-- Journeys that run the high-level demo script boot with the same
-- mod.route_sign complete style descriptor as the high-level-sign acceptance
-- suite (the catalogue accepts only complete records, never bases).
local function withDemoCapableGame(fn)
  withGame(fn, {
    windowStyleDescriptors = {
      {
        id = "mod.route_sign",
        role = "signpost",
        contentGeometry = { x = 16, y = 152, width = 216, height = 32 },
      },
    },
  })
end

-- The scheduler recorded the script's normal completion.
local function scriptEndedAt(game, scriptId)
  for _, record in ipairs(game.hosts.events.records) do
    if record.name == "script.ended" and record.payload.scriptId == scriptId and record.payload.completed == true then
      return true
    end
  end
  return false
end

-- Executable semantic nodes carry no sourceUnusedOut: opcode 55's final
-- operand is audited as unused, only raw decoded operands, provenance, and
-- audit data may keep it, and the compiled graph is the executable program,
-- so no node in it may carry the field.
local function assertNoSourceUnusedOut(game, scriptId, label)
  local composed = assert(game.runtime.scripts.composition:effective(scriptId))
  local graph = assert(composed.entries[1].graph, label .. " must compile to an executable graph")
  for _, node in pairs(graph.nodes) do
    Assert.isNil(node.sourceUnusedOut, label .. " must carry no sourceUnusedOut in executable nodes")
  end
end

-- Opcode 21 is terminal in the executable program: every signal_caller node
-- has no linear continuation edge, and the script actually ends its contexts
-- through the signal tail.
local function assertSignalCallerTerminal(game, scriptId, label)
  local composed = assert(game.runtime.scripts.composition:effective(scriptId))
  local graph = assert(composed.entries[1].graph, label .. " must compile to an executable graph")
  local count = 0
  for _, node in pairs(graph.nodes) do
    if node.op == "signal_caller" then
      count = count + 1
      Assert.isNil(node.next, label .. ": signal_caller must be terminal, never a linear continuation")
    end
  end
  Assert.isTrue(count > 0, label .. " must end its contexts through signal_caller")
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

  -- The child context ends at its signal_caller tail (opcode 21): the
  -- source commands that follow the signal in the same script (the next
  -- branch's wipe/hide) must never run. Probing past the wipe-out proves no
  -- command is re-queued by an accidental continuation.
  for _ = 1, 8 do
    game:step()
    Assert.equal(signpostStatus(game).command, "nop", label .. ": nothing may run after the child's signal_caller tail")
    Assert.isFalse(signpostStatus(game).active, label .. ": the signpost must stay closed after the signal tail")
  end
  Assert.equal(
    #scriptFaults(game),
    0,
    label .. ": the signal tail probe must not fault, got: " .. faultCode(scriptFaults(game))
  )
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

-- The number of glyph tokens the signpost window currently shows; the fill
-- contract is observable as a jump from a partial print to the whole
-- message.
local function visibleGlyphCount(game)
  local count = 0
  for _, tokens in ipairs(signpostStatus(game).visibleLines) do
    for _, token in ipairs(tokens) do
      if token.kind == "glyph" then
        count = count + 1
      end
    end
  end
  return count
end

-- Walk the real set-signpost-map script into the middle of its live typed
-- print: opcode 59 has started and at least one glyph is already revealed,
-- so an A/B edge still lands on a live print.
local function advanceToLivePrint(game)
  game:startScript(SET_SIGNPOST_MAP)
  Assert.equal(#scriptFaults(game), 0, "the set-signpost-map script must not fault at opcode 56")
  advanceSetSignpostMapThroughWipe(game)
  game:step()
  Assert.equal(
    #scriptFaults(game),
    0,
    "opcode 59 must not fault: TrainerTips starts a typed print, got: " .. faultCode(scriptFaults(game))
  )
  Assert.isFalse(signpostStatus(game).printDone, "opcode 59 must type at the player text speed, not instantly")
  Assert.isTrue(signpostStatus(game).active, "the signpost stays presented while Trainer Tips prints")
  game:advanceUntil("the typed print is partway through", function()
    return visibleGlyphCount(game) >= 1
  end, 16)
  Assert.isFalse(signpostStatus(game).printDone, "the print must still be live when the edge arrives")
  return game
end

-- The shared post-fill contract for A and B: the window stays modal, the
-- command is untouched, the whole message is revealed on the input tick,
-- and no script fault is produced.
local function assertFillContract(game, label)
  Assert.isTrue(signpostStatus(game).active, label .. " must not dismiss the signpost")
  Assert.equal(signpostStatus(game).command, "nop", label .. " must not change the signpost command")
  Assert.isTrue(signpostStatus(game).printDone, label .. " must reveal the whole message on the input tick")
  Assert.equal(#scriptFaults(game), 0, label .. " must not fault, got: " .. faultCode(scriptFaults(game)))
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
    -- The executable program keeps the audited unused operand out of the
    -- semantic IR and keeps the real child's signal_caller terminal.
    assertNoSourceUnusedOut(game, DIRECTION_SIGNPOST, "the direction-signpost program")
    assertSignalCallerTerminal(game, "common.signpost", "the std_signpost child program")
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

-- A during the live Trainer Tips print is the instant-fill operation, not
-- a dismissal and not a no-op: the whole message reveals on the input tick,
-- the signpost window stays open, the command is unchanged, and the task
-- finishes with the normal print-complete result 2. The script then resumes
-- into the real std_signpost child, which waits for its own dismissal and
-- wipes the sign out.
function T.tests.trainer_tips_a_during_print_fills_the_window_and_completes_with_result_two()
  withGame(function(game)
    advanceToLivePrint(game)
    local before = visibleGlyphCount(game)

    game:pressAction()
    assertFillContract(game, "A during the print")
    Assert.isTrue(visibleGlyphCount(game) > before, "A must reveal more than the partial print showed")

    -- The script resumes into the real std_signpost child on the following
    -- scheduler tick, which copies the completion result 2.
    game:advanceUntil("opcode 59 writes its completion result 2", function()
      return game.runtime.scripts.worldState:getVar(SPECIAL_RESULT) == 2
    end, 8)
    Assert.equal(
      #scriptFaults(game),
      0,
      "the std_signpost child must not fault, got: " .. faultCode(scriptFaults(game))
    )
    Assert.isTrue(signpostStatus(game).active, "the std_signpost child keeps the window open while it waits")

    game:pressAction()
    assertStdSignpostWipeOut(game, "trainer tips instant fill")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      0,
      "the std_signpost WaitSignpost must write its dismissal result 0"
    )
  end)
end

-- B (the cancel edge) performs the same instant fill as A: the whole
-- message reveals on the input tick, the window stays open, the command is
-- unchanged, and the task finishes with result 2.
function T.tests.trainer_tips_b_during_print_fills_the_window_and_completes_with_result_two()
  withGame(function(game)
    advanceToLivePrint(game)
    local before = visibleGlyphCount(game)

    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    assertFillContract(game, "B during the print")
    Assert.isTrue(visibleGlyphCount(game) > before, "B must reveal more than the partial print showed")

    game:advanceUntil("opcode 59 writes its completion result 2", function()
      return game.runtime.scripts.worldState:getVar(SPECIAL_RESULT) == 2
    end, 8)
    Assert.equal(#scriptFaults(game), 0, "B during the print must not fault, got: " .. faultCode(scriptFaults(game)))
    Assert.isTrue(signpostStatus(game).active, "the signpost window stays open after a B fill completion")
  end)
end

-- Direction and A/B on the same live-print tick: the direction wins. The
-- print is interrupted rather than filled, the player turns to the pressed
-- direction, the window closes, and the task completes 0 — the source
-- directional-interruption path, unchanged by the fill operation.
function T.tests.trainer_tips_direction_and_action_same_tick_prefers_the_direction()
  withGame(function(game)
    advanceToLivePrint(game)

    local before = game:snapshot().player.facing
    local pressed = before == "south" and "west" or "south"
    game.runtime:press(pressed)
    game.runtime:pressAction()
    game:step()
    game.runtime:release(pressed)
    game.runtime:releaseAction()

    Assert.isFalse(signpostStatus(game).printDone, "the direction must interrupt the print instead of filling it")
    Assert.isFalse(signpostStatus(game).active, "the directional interrupt must close the signpost window")
    Assert.equal(signpostStatus(game).command, "nop")
    Assert.equal(game:snapshot().player.facing, pressed, "the directional interrupt must turn the player")
    Assert.equal(#scriptFaults(game), 0, "the same-tick edge must not fault, got: " .. faultCode(scriptFaults(game)))

    assertStdSignpostWipeOut(game, "trainer tips same-tick direction and action")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      0,
      "opcode 59 must write its directional interrupt result 0"
    )
  end)
end

-- Pointer/touch input is not a script input edge: while the Trainer Tips
-- print is live, pointer events must neither fill the print nor complete
-- the task — the print keeps typing at the player cadence and completes
-- with the normal result 2.
function T.tests.pointer_input_cannot_fill_the_trainer_tips_print()
  withGame(function(game)
    advanceToLivePrint(game)
    local resultBefore = game.runtime.scripts.worldState:getVar(SPECIAL_RESULT)

    game.runtime.input:pointerDown("mouse:1", 400, 300)
    game:step()
    game.runtime.input:pointerMove("mouse:1", 420, 310)
    game.runtime.input:pointerUp("mouse:1", 420, 310)
    game:step()

    Assert.isFalse(signpostStatus(game).printDone, "pointer input must not fill the typed print")
    Assert.equal(signpostStatus(game).command, "nop", "pointer input must not touch the signpost command")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      resultBefore,
      "pointer input must not complete the print task"
    )

    -- The print still completes at the ordinary cadence with result 2.
    game:advanceUntil("the trainer tips print completes at its normal cadence", function()
      return signpostStatus(game).printDone
    end, 64)
    game:advanceUntil("opcode 59 writes its completion result 2", function()
      return game.runtime.scripts.worldState:getVar(SPECIAL_RESULT) == 2
    end, 8)
    Assert.equal(#scriptFaults(game), 0, "the print completion must not fault, got: " .. faultCode(scriptFaults(game)))
  end)
end

-- Stale imported source appearance cannot leak into high-level signs: the
-- controller deliberately preserves the imported type/map appearance
-- through low-level hide/wipe-out (the low-level escape hatch), so a
-- high-level sign opened after an imported signpost dismissal must
-- explicitly clear it. One boot runs both real imported journeys: the
-- type-0 direction signpost and the type-2 trainer-tips script each
-- dismiss, and then the high-level demo script opens twice — every high-level
-- open (S.sign and S.trainerTip) must present with no source appearance.
function T.tests.imported_signpost_appearance_cannot_leak_into_high_level_signs()
  withDemoCapableGame(function(game)
    -- Journey 1: the imported type-0 direction signpost presents with its
    -- source appearance and dismisses through the real std_signpost cleanup.
    game:startScript(DIRECTION_SIGNPOST)
    Assert.deepEqual(signpostStatus(game).sourceAppearance, { game = "hgss", type = 0, map = 11 })
    advanceDirectionSignpostThroughWipe(game)
    game:step() -- opcode 60 installs its waiter
    game:pressAction() -- dismissal
    assertStdSignpostWipeOut(game, "imported direction-signpost dismissal")
    game:advanceUntil("the imported direction-signpost script ends", function()
      return scriptEndedAt(game, DIRECTION_SIGNPOST)
    end, 8)

    -- The high-level sign opens right after the imported type-0 dismissal:
    -- its semantic presentation must not inherit the stale appearance.
    game:startScript(DEMO_SIGNPOST)
    local status = signpostStatus(game)
    Assert.isTrue(status.active, "S.sign must present the window immediately")
    Assert.isNil(status.sourceAppearance, "S.sign must not inherit the imported type-0 appearance")
    Assert.isTrue(status.printDone, "S.sign must print its message instantly")
    game:pressAction()
    game:advanceUntil("S.trainerTip opens its typed print", function()
      local tip = signpostStatus(game)
      return tip.active and not tip.printDone
    end, 8)
    Assert.isNil(signpostStatus(game).sourceAppearance, "S.trainerTip must not inherit the imported type-0 appearance")
    game:advanceUntil("the trainer tip print completes", function()
      return signpostStatus(game).printDone
    end, 64)
    game:pressAction()
    game:advanceUntil("the demo script ends after the first run", function()
      return scriptEndedAt(game, DEMO_SIGNPOST)
    end, 8)

    -- Journey 2: the imported type-2 trainer-tips script presents with its
    -- own source appearance, types, and dismisses the same way.
    game:startScript(SET_SIGNPOST_MAP)
    Assert.deepEqual(signpostStatus(game).sourceAppearance, { game = "hgss", type = 2, map = 0 })
    advanceSetSignpostMapThroughWipe(game)
    game:step() -- opcode 59 starts the typed print
    game:advanceUntil("the imported trainer-tips print completes", function()
      return signpostStatus(game).printDone
    end, 64)
    game:step() -- the std_signpost child installs its waiter
    game:pressAction() -- dismissal
    assertStdSignpostWipeOut(game, "imported trainer-tips dismissal")
    game:advanceUntil("the imported trainer-tips script ends", function()
      return scriptEndedAt(game, SET_SIGNPOST_MAP)
    end, 8)

    -- The second high-level run opens with no source appearance again.
    game:startScript(DEMO_SIGNPOST)
    status = signpostStatus(game)
    Assert.isTrue(status.active, "S.sign must present the window immediately")
    Assert.isNil(status.sourceAppearance, "S.sign must not inherit the imported type-2 appearance")
    game:pressAction()
    game:advanceUntil("S.trainerTip opens its typed print again", function()
      local tip = signpostStatus(game)
      return tip.active and not tip.printDone
    end, 8)
    Assert.isNil(signpostStatus(game).sourceAppearance, "S.trainerTip must not inherit the imported type-2 appearance")
    game:advanceUntil("the trainer tip print completes again", function()
      return signpostStatus(game).printDone
    end, 64)
    game:pressAction()
    game:advanceUntil("the demo script ends after the second run", function()
      return scriptEndedAt(game, DEMO_SIGNPOST)
    end, 8)
    Assert.equal(
      #scriptFaults(game),
      0,
      "the imported-to-high-level journey must run without faulting, got: " .. faultCode(scriptFaults(game))
    )
  end)
end

-- The required wait_signpost_action fault/cancellation contract: a script
-- that presents the signpost, starts a wipe, and blocks in
-- wait_signpost_action must release everything when its execution
-- environment is cancelled. After scheduler teardown the signpost is
-- inactive, the printer is absent, the command is idle, and no modal
-- ownership remains.
function T.tests.wait_signpost_action_environment_cancel_leaves_no_modal_ownership()
  withGame(function(game)
    game:startScript(DIRECTION_SIGNPOST)
    Assert.equal(#scriptFaults(game), 0, "the direction-signpost script must not fault at opcode 55")
    Assert.isTrue(signpostStatus(game).active, "opcode 55 must present the signpost window immediately")
    game:step()
    Assert.equal(signpostStatus(game).command, "wipe_in", "opcode 57 must queue its source command")
    game:step()
    Assert.equal(signpostStatus(game).command, "wipe_in", "opcode 58 must block while the wipe is busy")
    Assert.equal(
      signpostStatus(game).logicalYOffset,
      -32,
      "the wipe must be mid-motion when the environment is cancelled"
    )

    local scheduler = game.runtime.scripts.scheduler
    local environmentId = assert(scheduler:foregroundEnvironmentId(), "the signpost script must own the foreground")
    scheduler:cancelEnvironment(environmentId, "acceptance injected cancellation")

    local status = signpostStatus(game)
    Assert.isFalse(status.active, "the cancelled wait must leave the signpost inactive")
    Assert.isFalse(status.printDone, "the cancelled wait must leave no printer behind")
    Assert.deepEqual(status.visibleLines, {}, "the cancelled wait must leave no printer behind")
    Assert.equal(status.command, "nop", "the cancelled wait must leave the command idle")

    local snapshot = game:snapshot()
    Assert.isFalse(snapshot.dialogue.modal, "no dialogue modal may remain after the cancellation")
    Assert.isFalse(snapshot.fieldLocked, "the field must be unlocked after the cancellation")
    Assert.equal(#scheduler:liveInstances(), 0, "no script instance may remain after the cancellation")
    Assert.equal(#scheduler:tasks(), 0, "no task record may remain after the cancellation")
    Assert.isNil(scheduler:foregroundEnvironmentId(), "no foreground environment may remain after the cancellation")

    game:step()
    Assert.isFalse(signpostStatus(game).active, "the signpost must stay inactive on later ticks")
    Assert.equal(signpostStatus(game).command, "nop", "the command must stay idle on later ticks")
  end)
end

-- The controller-owned wipe interpolation history (the renderer contract
-- published to W3): every status read exposes a previous/current
-- logical-offset pair, the previous offset of each read equals the current
-- offset of the immediately preceding read, and both fields initialize and
-- reset coherently. This is the exact state a stateless renderer
-- interpolates against, independent of render-call count.
function T.tests.signpost_status_exposes_paired_wipe_interpolation_history()
  withGame(function(game)
    game:startScript(DIRECTION_SIGNPOST)
    local status = signpostStatus(game)
    Assert.equal(status.previousLogicalYOffset, status.logicalYOffset, "the interpolation pair must start coherent")
    Assert.isTrue(
      type(status.previousLogicalYOffset) == "number" and status.previousLogicalYOffset % 1 == 0,
      "previousLogicalYOffset must be an integer"
    )
    local priorCurrent = status.logicalYOffset

    -- Opcode 57 queues WIPE_IN one tick later without executing it.
    game:step()
    status = signpostStatus(game)
    Assert.equal(status.previousLogicalYOffset, priorCurrent, "each read must pair with the previous tick's offset")
    Assert.equal(status.command, "wipe_in")
    priorCurrent = status.logicalYOffset

    -- The wipe then moves exactly one 16px step per fixed tick, with the
    -- history pair following the motion.
    local expected = { -32, -16, 0 }
    for _, offset in ipairs(expected) do
      game:step()
      status = signpostStatus(game)
      Assert.equal(status.previousLogicalYOffset, priorCurrent, "each read must pair with the previous tick's offset")
      Assert.equal(status.logicalYOffset, offset, "the wipe must move one 16px step per tick")
      priorCurrent = status.logicalYOffset
    end

    -- The endpoint-check update returns the command to nop with both
    -- history fields reset coherently to the presented offset.
    game:step()
    status = signpostStatus(game)
    Assert.equal(status.command, "nop")
    Assert.equal(status.previousLogicalYOffset, 0)
    Assert.equal(status.logicalYOffset, 0)
  end)
end

return T
