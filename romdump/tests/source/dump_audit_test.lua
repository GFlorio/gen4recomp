local Assert = require("tests.support.Assert")
local DumpAudit = require("romdump.src.source.DumpAudit")
local DumpFixture = require("tests.support.DumpFixture")

local T = {}

local HG = "heartgold/"

function T.passes_on_a_complete_dump()
  local d = DumpFixture.extract()
  local report = DumpAudit.run("heartgold", d.cache)
  Assert.isTrue(report.ok, "expected audit to pass: " .. table.concat(DumpAudit.lines(report), " | "))
  Assert.equal(report.fileCheck.total, 7)
  Assert.isTrue(report.requiredNarcs.ok)
  Assert.equal(report.matrix.name, "MM")
  Assert.equal(report.matrix.width, 2)
end

function T.fails_when_readiness_is_broken()
  local d = DumpFixture.extract()
  d.backend.files[HG .. "rom-dump.complete"] = nil
  local report = DumpAudit.run("heartgold", d.cache)
  Assert.isFalse(report.ok)
  Assert.equal(report.checks[1].name, "readiness")
  Assert.isFalse(report.checks[1].ok)
end

function T.fails_on_output_size_mismatch()
  local d = DumpFixture.extract()
  -- Truncate one dumped file so its size no longer matches the index.
  d.backend.files[HG .. "romfs/a/0/0/2"] = "X"
  local report = DumpAudit.run("heartgold", d.cache)
  Assert.isFalse(report.ok)
  Assert.isFalse(report.fileCheck.ok)
end

return { metadata = { layer = "unit" }, tests = T }
