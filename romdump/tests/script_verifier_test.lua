-- Translation-verifier unit tests: the classification checks that pin the
-- terminal protocol of the common-script context end (opcode 21) and the
-- surrounding stop/continue accounting on synthetic members. No ROM and no
-- decomp checkout required.

local Assert = require("tests.support.Assert")
local ScriptFixture = require("tests.support.ScriptFixture")
local ScriptBinaryDecoder = require("romdump.src.digest.script.ScriptBinaryDecoder")
local SemanticLowering = require("romdump.src.digest.script.SemanticLowering")
local Structurer = require("romdump.src.digest.script.Structurer")
local Verifier = require("romdump.src.digest.script.Verifier")
local CommandCatalog = require("romdump.src.digest.script.CommandCatalog")
local SourceCatalog = require("romdump.src.digest.script.SourceCatalog")

local T = {}

local CATALOG = {
  sounds = {},
  flags = {},
  vars = {},
  maps = {},
}

local function verify(bytes)
  local ir = assert(ScriptBinaryDecoder.parseMember(bytes, 5, "synthetic", { msgBank = 543, catalog = CATALOG }))
  local lowered = SemanticLowering.lowerScript(ir.scripts[0], ir, { stdCatalog = SourceCatalog.catalog() })
  local steps = Structurer.structure(lowered, 0)
  local report = Verifier.verifyScript(steps, ir.scripts[0], ir, lowered.omissions)
  return steps, report
end

-- The catalog itself owns the terminal classification: reverting opcode 21
-- to continue_same_tick must fail this assertion before any verifier run.
function T.opcode_21_is_stop_classified_in_the_catalog()
  Assert.equal(CommandCatalog.classification(21), CommandCatalog.STOP)
  Assert.equal(CommandCatalog.name(21), "ScrCmd_RestartCurrentScript")
end

-- A context that ends at its signal_caller must verify as a complete
-- terminal translation: the stop classification check requires the
-- terminal-op set to recognize the signal node.
function T.signal_caller_verifies_as_a_terminal_translation()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 21, args = {} },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, report = verify(bytes)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "signal_caller must verify")
  Assert.isTrue(report.complete)
end

-- The post-signal instructions of a context are ordinary covered source:
-- the verifier treats them as reachable fallthrough material and requires
-- them to stay covered, exactly like any other instruction.
function T.post_signal_instructions_stay_covered()
  local bytes = ScriptFixture.member({
    scripts = {
      {
        offset = 0x20,
        instructions = {
          { op = 21, args = {} },
          { op = 30, args = { { value = 3, width = 2 } } },
          { op = 2, args = {} },
        },
      },
    },
  })
  local _, report = verify(bytes)
  Assert.isTrue(report.ok, report.problems[1] and report.problems[1].message or "post-signal code must verify")
  Assert.isTrue(report.complete)
end

return { tests = T }
