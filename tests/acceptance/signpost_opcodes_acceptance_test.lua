-- Production-composed contracts for source opcodes 55-58 through the real
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
-- nop; the script resumes on the following tick and faults at its next
-- unsupported source opcode (60 in script 14, 59 in script 13). Rendering
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
-- The next unsupported source opcode after each script's wait
-- (WaitSignpost in script 14, TrainerTips in script 13), so the script
-- faults there after the wait completes: the arrival time of that fault is
-- what pins the block-until-nop contract.
local NEXT_UNSUPPORTED_DIRECTION = 60
local NEXT_UNSUPPORTED_TIPS = 59

-- The unused result operand of opcode 55 (VAR_SPECIAL_RESULT, 0x800C): the
-- source handler never reads or writes it.
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

local function faultCode(faults)
  return faults[1] and faults[1].code or "none"
end

-- The real New Bark town direction sign (DirectionSignpostEx): opcode 55
-- selects SHOW, executes it immediately, expands its message and prints it
-- instantly, yields exactly one tick, and never writes the unused out
-- operand. The script then runs opcode 57 one tick later (queuing WIPE_IN
-- without executing it), opcode 58 blocks until the wipe completes, and the
-- script faults at the next unsupported source opcode (60) on the tick
-- after the command returns to nop.
function T.tests.direction_signpost_shows_immediately_yields_once_and_never_writes_its_out_operand()
  withGame(function(game)
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

    -- The unused result operand is never written: the sentinel survives.
    Assert.equal(game.runtime.scripts.worldState:getVar(SPECIAL_RESULT), 77)

    -- 57 (SetSignpostAction) runs exactly one scheduler tick later, stores
    -- the raw source command WIPE_IN (operand 3), and yields one tick:
    -- the wipe must not have started, so the offset is still the hidden
    -- position.
    game:step()
    local afterAction = signpostStatus(game)
    local afterActionFaults = scriptFaults(game)
    Assert.equal(#afterActionFaults, 0, "the script must not fault at opcode 57, got: " .. faultCode(afterActionFaults))
    Assert.equal(
      afterAction.command,
      "wipe_in",
      "opcode 57 must queue its source command one tick after opcode 55, got: " .. tostring(afterAction.command)
    )
    Assert.equal(afterAction.logicalYOffset, -48, "opcode 57 must not execute its queued command")
    Assert.equal(game.runtime.scripts.worldState:getVar(SPECIAL_RESULT), 77)

    -- 58 (WaitSignpostAction) runs one tick later while the command is
    -- still busy, so it installs a native waiter instead of continuing in
    -- its own tick: the wipe advances exactly one 16px step and no error
    -- can arrive while the command is still running.
    game:step()
    local afterWait = signpostStatus(game)
    local afterWaitFaults = scriptFaults(game)
    Assert.equal(
      #afterWaitFaults,
      0,
      "opcode 58 must block while the command is busy, got: " .. faultCode(afterWaitFaults)
    )
    Assert.equal(afterWait.command, "wipe_in", "the wipe must still be in motion while the wait is active")
    Assert.equal(afterWait.logicalYOffset, -32, "the signpost controller must advance once per scheduler tick")

    -- The waiter completes only after the wipe reaches its endpoint and
    -- the command returns to nop; the script resumes on the following
    -- scheduler tick and faults at its next unsupported source opcode.
    game:advanceUntil("the signpost command returns to nop", function()
      return signpostStatus(game).command == "nop"
    end, 8)
    Assert.equal(#scriptFaults(game), 0, "the wait must not complete before the signpost command is nop")
    game:step()
    local later = scriptFaults(game)
    Assert.equal(
      #later,
      1,
      "the script must resume exactly one tick after the command returns to nop, got: " .. tostring(#later)
    )
    Assert.equal(later[1].code, "SCRIPT_UNSUPPORTED_REACHABLE")
    Assert.equal(
      later[1].command,
      NEXT_UNSUPPORTED_DIRECTION,
      "the script must have advanced past opcode 58 to opcode 60, got: " .. tostring(later[1].command)
    )
    Assert.equal(game.runtime.scripts.worldState:getVar(SPECIAL_RESULT), 77)
  end)
end

-- The real New Bark TrainerTipsEx script: opcode 56 writes the source
-- appearance and queues SHOW without executing it, prints nothing, and
-- yields exactly one tick; the queued SHOW runs at the next tick's field
-- update. Opcode 57 then queues WIPE_IN and yields, opcode 58 blocks until
-- the wipe completes, and the script faults at the next unsupported source
-- opcode (59).
function T.tests.set_signpost_map_queues_show_and_yields_once()
  withGame(function(game)
    game:startScript(SET_SIGNPOST_MAP)

    local faults = scriptFaults(game)
    Assert.equal(#faults, 0, "the set-signpost-map script must not fault at opcode 56, got: " .. faultCode(faults))

    -- 56 queues SHOW: the command is stored but not executed, the window
    -- is not presented, and no text is invented.
    local status = signpostStatus(game)
    Assert.isFalse(status.active, "opcode 56 must not execute SHOW immediately")
    Assert.equal(status.command, "show")
    Assert.deepEqual(status.sourceAppearance, { game = "hgss", type = 2, map = 0 })
    Assert.deepEqual(status.visibleLines, {})
    Assert.isFalse(status.printDone)

    -- One tick later the queued SHOW executes at the top of the tick, then
    -- opcode 57 stores WIPE_IN without executing it and yields.
    game:step()
    local afterAction = signpostStatus(game)
    local afterActionFaults = scriptFaults(game)
    Assert.equal(#afterActionFaults, 0, "the script must not fault at opcode 57, got: " .. faultCode(afterActionFaults))
    Assert.isTrue(afterAction.active, "the queued SHOW must run at the next field update")
    Assert.equal(
      afterAction.command,
      "wipe_in",
      "opcode 57 must queue its source command one tick after opcode 56, got: " .. tostring(afterAction.command)
    )
    Assert.equal(afterAction.logicalYOffset, -48, "opcode 57 must not execute its queued command")

    -- Same block-until-nop contract as the direction-signpost script.
    game:step()
    local afterWait = signpostStatus(game)
    local afterWaitFaults = scriptFaults(game)
    Assert.equal(
      #afterWaitFaults,
      0,
      "opcode 58 must block while the command is busy, got: " .. faultCode(afterWaitFaults)
    )
    Assert.equal(afterWait.command, "wipe_in", "the wipe must still be in motion while the wait is active")
    Assert.equal(afterWait.logicalYOffset, -32, "the signpost controller must advance once per scheduler tick")

    game:advanceUntil("the signpost command returns to nop", function()
      return signpostStatus(game).command == "nop"
    end, 8)
    Assert.equal(#scriptFaults(game), 0, "the wait must not complete before the signpost command is nop")
    game:step()
    local later = scriptFaults(game)
    Assert.equal(
      #later,
      1,
      "the script must resume exactly one tick after the command returns to nop, got: " .. tostring(#later)
    )
    Assert.equal(later[1].code, "SCRIPT_UNSUPPORTED_REACHABLE")
    Assert.equal(
      later[1].command,
      NEXT_UNSUPPORTED_TIPS,
      "the script must have advanced past opcode 58 to opcode 59, got: " .. tostring(later[1].command)
    )
  end)
end

return T
