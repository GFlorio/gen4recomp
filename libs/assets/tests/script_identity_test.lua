-- Canonical generated script identities: validate the shared project-level
-- formatter used by both the ROM producer and runtime interaction binding.

local Assert = require("tests.support.Assert")
local ScriptIdentity = require("libs.assets.src.ScriptIdentity")

local T = {}

function T.formats_zero_based_vanilla_script_ids()
  Assert.equal(ScriptIdentity.formatVanilla(0, 0), "vanilla.hgss.scr_seq.0000.script_000")
  Assert.equal(ScriptIdentity.formatVanilla(842, 1), "vanilla.hgss.scr_seq.0842.script_001")
end

function T.rejects_invalid_bank_and_index_values()
  for _, values in ipairs({
    { -1, 0 },
    { 0, -1 },
    { 1.5, 0 },
    { 0, 1.5 },
    { "842", 0 },
    { 842, "1" },
  }) do
    Assert.throws(function()
      ScriptIdentity.formatVanilla(values[1], values[2])
    end)
  end
end

return { tests = T }
