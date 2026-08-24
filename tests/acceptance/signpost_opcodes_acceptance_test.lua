-- Production-composed contract for the imported signpost material: the two
-- real New Bark sign scripts (scr_seq member 842, message bank 542) run
-- through the real classification/lowering/schema/runtime/host/task path in
-- one boot. Script 014 (DirectionSignpostEx, opcode 55 at entry) must present
-- the signpost window immediately and print its message instantly without
-- writing its unused result operand; script 013 (TrainerTipsEx, 56 at entry)
-- must only queue SHOW. Opcode 57 (SetSignpostAction) then runs exactly one
-- scheduler tick later, stores its raw source command (WIPE_IN, operand 3)
-- without executing it, and yields one tick. Opcode 58 (WaitSignpostAction)
-- runs one tick later while the command is still busy and blocks until the
-- fixed-tick wipe completes and the command returns to nop. Opcode 59
-- (TrainerTips) types its message into the existing signpost window at the
-- player text speed and completes only through the scheduler result
-- reference: 2 on normal completion, 0 on a directional interrupt. Opcode 60
-- (WaitSignpost) always installs a waiter and completes on A/B with result 0.
-- After the signpost opcodes, both scripts resume into the real
-- common.signpost child script (std_signpost): the child copies the special
-- result, branches on it, and for results 0/2 queues WIPE_OUT and signals
-- the caller, so the whole cleanup runs from the actual ROM-derived script
-- material with zero script faults. The child context ends at its
-- signal_caller tail (opcode 21): the source commands that follow the signal
-- in the same script never run, and the executable semantic program keeps
-- signal_caller terminal with no linear continuation. The imported scripts
-- keep the low-level nodes, pointer/touch input never fills the typed
-- print, and a high-level sign opened after an imported signpost dismissal
-- must not inherit the imported source appearance. Scheduler environment
-- cancellation mid-wipe releases every signpost-owned resource and returns
-- the field to an unlocked, modal-free boundary. Rendering stays trapped.
-- Input-edge variants of these journeys
-- (directional dismissals, A/B fills, same-tick priority, cancellation) are
-- owned by the engine-level script signpost-opcode suite with synthetic
-- scripts; this boot proves the real ROM material.

local Assert = require("tests.support.Assert")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "signpost", "hgss", "mod" },
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

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = { acceptanceScripts = AcceptanceScripts, recordingScriptHosts = true },
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

-- How many times the scheduler recorded the script's normal completion;
-- scripts are restarted within this journey, so callers wait for a specific
-- run count rather than the first record.
local function scriptEndedCount(game, scriptId)
  local count = 0
  for _, record in ipairs(game:hostEvents().records) do
    if record.name == "script.ended" and record.payload.scriptId == scriptId and record.payload.completed == true then
      count = count + 1
    end
  end
  return count
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
  for _, record in ipairs(game:hostEvents().records) do
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

-- Walk the direction-signpost script (55 at entry) through opcode 58's
-- block and the wipe end, ending on the tick where the command is nop. The
-- caller then steps into opcode 60.
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

-- The number of glyph tokens the signpost window currently shows; a live
-- typed print is observable as a partial count below the full message.
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

-- The whole imported-material journey in one production boot: the real
-- type-0 direction signpost (55 at entry) presents, wipes, waits, dismisses,
-- and cleans up through the real std_signpost child; a high-level demo sign
-- and trainer tip opened right after must not inherit the imported
-- appearance; the real type-2 trainer-tips script (56 at entry) types its
-- print at the player cadence, completes with result 2, and dismisses the
-- same way; pointer input never fills the typed print; a second high-level
-- run inherits nothing; and environment cancellation mid-wipe releases every
-- signpost-owned resource.
function T.tests.the_real_imported_signpost_journeys_complete_and_high_level_signs_inherit_no_appearance()
  withGame(function(game)
    -- The imported programs keep the low-level nodes: no high-level op
    -- rewrites the imported sequence, and the real child keeps its
    -- signal_caller terminal.
    assertNoHighLevelSignOps(game, DIRECTION_SIGNPOST, "the direction-signpost override")
    assertSignalCallerTerminal(game, "common.signpost", "the std_signpost child program")

    -- Journey 1: the real type-0 direction signpost. The unused result
    -- operand sentinel survives opcode 55 and the whole wipe journey (57
    -- queues WIPE_IN one tick later without executing it, 58 blocks until
    -- the wipe returns the command to nop).
    game:setWorldState({ variable = SPECIAL_RESULT, value = 77 })
    game:startScript(DIRECTION_SIGNPOST)
    local status = signpostStatus(game)
    Assert.isTrue(status.active, "opcode 55 must present the signpost window immediately")
    Assert.equal(status.command, "nop")
    Assert.deepEqual(status.sourceAppearance, { game = "hgss", type = 0, map = 11 })
    Assert.isTrue(#status.visibleLines > 0, "opcode 55 must print its message instantly")
    Assert.isTrue(status.printDone, "the instant signpost print must be complete")
    Assert.equal(game.runtime.scripts.worldState:getVar(SPECIAL_RESULT), 77, "opcode 55 must not write its out operand")
    advanceDirectionSignpostThroughWipe(game)
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      77,
      "the wipe journey must not write the operand"
    )

    -- Opcode 60 installs its own waiter instead of faulting; A dismisses
    -- the signpost (the semantic edge touch and mouse map to): result 0,
    -- the window closes, and the real std_signpost cleanup wipes the sign
    -- out and ends the script.
    game:step()
    Assert.equal(#scriptFaults(game), 0, "opcode 60 must not fault, got: " .. faultCode(scriptFaults(game)))
    Assert.isTrue(signpostStatus(game).active, "the signpost stays presented while WaitSignpost waits")
    game:pressAction()
    Assert.isFalse(signpostStatus(game).active, "A must dismiss the signpost window (textbox_open = false)")
    Assert.equal(signpostStatus(game).command, "nop")
    Assert.equal(#scriptFaults(game), 0, "the dismissal itself must not fault, got: " .. faultCode(scriptFaults(game)))
    assertStdSignpostWipeOut(game, "direction sign A dismissal")
    Assert.equal(game.runtime.scripts.worldState:getVar(SPECIAL_RESULT), 0, "opcode 60 must write result 0")
    game:advanceUntil("the imported direction-signpost script ends", function()
      return scriptEndedCount(game, DIRECTION_SIGNPOST) >= 1
    end, 8)

    -- The high-level sign opens right after the imported type-0 dismissal:
    -- its semantic presentation must not inherit the stale appearance.
    game:startScript(DEMO_SIGNPOST)
    status = signpostStatus(game)
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
      return scriptEndedCount(game, DEMO_SIGNPOST) >= 1
    end, 8)

    -- Journey 2: the real type-2 trainer-tips script. Opcode 56 writes the
    -- source appearance and queues SHOW without executing it; the queued
    -- SHOW runs at the next tick's field update, 57 then queues WIPE_IN,
    -- and 58 blocks until the wipe completes.
    game:startScript(SET_SIGNPOST_MAP)
    status = signpostStatus(game)
    Assert.isFalse(status.active, "opcode 56 must not execute SHOW immediately")
    Assert.equal(status.command, "show")
    Assert.deepEqual(status.sourceAppearance, { game = "hgss", type = 2, map = 0 })
    Assert.deepEqual(status.visibleLines, {})
    Assert.isFalse(status.printDone)
    advanceSetSignpostMapThroughWipe(game)

    -- One tick past nop: opcode 59 types its message into the signpost
    -- window at the player text speed.
    game:step()
    Assert.equal(#scriptFaults(game), 0, "opcode 59 must not fault, got: " .. faultCode(scriptFaults(game)))
    Assert.isFalse(signpostStatus(game).printDone, "opcode 59 must type at the player text speed, not instantly")
    Assert.isTrue(signpostStatus(game).active, "the signpost stays presented while Trainer Tips prints")

    -- Pointer/touch input is not a script input edge: while the print is
    -- live, pointer events must neither fill the print nor complete the
    -- task -- the print keeps typing at the player cadence.
    game:advanceUntil("the typed print is partway through", function()
      return visibleGlyphCount(game) >= 1
    end, 16)
    Assert.isFalse(signpostStatus(game).printDone, "the print must still be live when the pointer events arrive")
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

    -- The print completes at the fixed-tick cadence without any input; the
    -- script then resumes into the real std_signpost child, whose own
    -- WaitSignpost (opcode 60) keeps the window open, and opcode 59's
    -- normal completion result 2 lands on the promotion tick.
    game:advanceUntil("the trainer tips print completes", function()
      return signpostStatus(game).printDone
    end, 64)
    Assert.equal(#scriptFaults(game), 0, "the print completion must not fault, got: " .. faultCode(scriptFaults(game)))
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

    -- A dismisses the child's wait, which writes its own result 0 over the
    -- completion value and wipes the sign out.
    game:pressAction()
    assertStdSignpostWipeOut(game, "trainer tips normal completion")
    Assert.equal(
      game.runtime.scripts.worldState:getVar(SPECIAL_RESULT),
      0,
      "the std_signpost WaitSignpost must write its dismissal result 0"
    )
    game:advanceUntil("the imported trainer-tips script ends", function()
      return scriptEndedCount(game, SET_SIGNPOST_MAP) >= 1
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
      return scriptEndedCount(game, DEMO_SIGNPOST) >= 2
    end, 8)

    -- Environment cancellation mid-wipe releases every signpost-owned
    -- resource: the window is hidden, the printer is gone, the command is
    -- idle, no script instance or task remains, and the field returns to an
    -- unlocked, modal-free boundary that stays clean on later ticks.
    game:startScript(DIRECTION_SIGNPOST)
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
    status = signpostStatus(game)
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

    Assert.equal(
      #scriptFaults(game),
      0,
      "the whole imported-material journey must run without faulting, got: " .. faultCode(scriptFaults(game))
    )
  end)
end

return T
