-- Reference-oriented SSEQ fixture coverage. Branch operands in this fixture
-- are encoded relative to the DATA payload, independently of the lowering
-- implementation's source-offset representation.

local Assert = require("tests.support.Assert")
local SequenceLowering = require("romdump.src.digest.audio.SequenceLowering")
local SseqFixture = require("tests.support.SseqFixture")

local T = {}

function T.data_relative_branch_operands_reach_the_first_command()
  local bytes = SseqFixture.build({
    { op = "fe", mask = 3 },
    { op = "open_track", track = 1, target = { cmd = 4 } },
    { op = "call", target = { cmd = 4 } },
    { op = "jump", target = { cmd = 4 } },
    { op = "fin" },
  })
  local program, err = SequenceLowering.lower(bytes, { sequenceId = 0, symbol = "SEQ_FIXTURE" })
  Assert.notNil(program, "data-relative targets should lower: " .. tostring(err))
  program = assert(program)
  Assert.equal(program.entry, 1)
  Assert.equal(program.instructions[1].target, 3)
  Assert.equal(program.instructions[2].target, 3)
  Assert.equal(program.instructions[3].target, 3)
end

return { tests = T }
