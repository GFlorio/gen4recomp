-- Production-composed contracts for source opcodes 55 and 56 through the
-- real classification/lowering/schema/runtime/host path. The two real New
-- Bark sign scripts (scr_seq member 842, message bank 542) start with the
-- signpost opcodes: script 14 is DirectionSignpostEx (55 at entry), script
-- 13 is TrainerTipsEx (56 at entry). 55 must present the signpost window
-- immediately and print its message instantly without writing its unused
-- result operand; 56 must only queue SHOW. Both yield exactly one
-- scheduler tick, so the script reaches its next source opcode (57, still
-- unsupported) exactly one tick later. Rendering stays trapped.

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
-- The next source opcode in both scripts (SetSignpostAction), still
-- unsupported, so the script faults there after the signpost opcodes have
-- run and yielded.
local NEXT_SOURCE_OPCODE = 57

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

-- The real New Bark town direction sign (DirectionSignpostEx): opcode 55
-- selects SHOW, executes it immediately, expands its message and prints it
-- instantly, yields exactly one tick, and never writes the unused out
-- operand (the script then faults at the next source opcode, 57, whose
-- runtime support is not wired yet).
function T.tests.direction_signpost_shows_immediately_yields_once_and_never_writes_its_out_operand()
  withGame(function(game)
    game:setWorldState({ variable = SPECIAL_RESULT, value = 77 })
    game:startScript(DIRECTION_SIGNPOST)

    local faults = scriptFaults(game)
    Assert.equal(
      #faults,
      0,
      "the direction-signpost script must not fault at opcode 55, got: " .. tostring(faults[1] and faults[1].code)
    )

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

    -- Exactly one scheduler tick later the script reaches its next source
    -- opcode (57, unsupported here): the signpost opcode yielded exactly
    -- once, it did not continue in its own tick.
    game:step()
    local later = scriptFaults(game)
    Assert.equal(
      #later,
      1,
      "the script must fault exactly one tick after the signpost opcode, got: " .. tostring(#later)
    )
    Assert.equal(later[1].code, "SCRIPT_UNSUPPORTED_REACHABLE")
    Assert.equal(
      later[1].command,
      NEXT_SOURCE_OPCODE,
      "the script must have advanced to opcode 57, not faulted at the signpost opcode"
    )
    Assert.equal(game.runtime.scripts.worldState:getVar(SPECIAL_RESULT), 77)
  end)
end

-- The real New Bark TrainerTipsEx script: opcode 56 writes the source
-- appearance and queues SHOW without executing it, prints nothing, and
-- yields exactly one tick.
function T.tests.set_signpost_map_queues_show_and_yields_once()
  withGame(function(game)
    game:startScript(SET_SIGNPOST_MAP)

    local faults = scriptFaults(game)
    Assert.equal(
      #faults,
      0,
      "the set-signpost-map script must not fault at opcode 56, got: " .. tostring(faults[1] and faults[1].code)
    )

    -- 56 queues SHOW: the command is stored but not executed, the window
    -- is not presented, and no text is invented.
    local status = signpostStatus(game)
    Assert.isFalse(status.active, "opcode 56 must not execute SHOW immediately")
    Assert.equal(status.command, "show")
    Assert.deepEqual(status.sourceAppearance, { game = "hgss", type = 2, map = 0 })
    Assert.deepEqual(status.visibleLines, {})
    Assert.isFalse(status.printDone)

    -- Same one-tick yield contract as opcode 55.
    game:step()
    local later = scriptFaults(game)
    Assert.equal(
      #later,
      1,
      "the script must fault exactly one tick after the signpost opcode, got: " .. tostring(#later)
    )
    Assert.equal(later[1].code, "SCRIPT_UNSUPPORTED_REACHABLE")
    Assert.equal(
      later[1].command,
      NEXT_SOURCE_OPCODE,
      "the script must have advanced to opcode 57, not faulted at the signpost opcode"
    )
  end)
end

return T
