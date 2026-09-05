local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local ScriptHeader = require("romdump.src.digest.script.ScriptHeader")

local T = {}

local function u16(value)
  return string.char(value % 256, math.floor(value / 256) % 256)
end

function T.decodes_ordered_on_frame_rules_and_targets()
  local bytes = u16(0x0101)
    .. u16(0)
    .. u16(0)
    .. u16(0x4106)
    .. u16(3)
    .. u16(7)
    .. u16(0x4106)
    .. u16(0)
    .. u16(1)
    .. u16(0)
  local result = assert(ScriptHeader.parse(bytes, { mapId = 618, memberId = 618, scriptBankId = 845 }))
  Assert.deepEqual(result, {
    {
      type = "on_frame_eq",
      rules = {
        { variableId = 0x4106, equals = 3, scriptId = "vanilla.hgss.scr_seq.0845.script_006" },
        { variableId = 0x4106, equals = 0, scriptId = "vanilla.hgss.scr_seq.0845.script_000" },
      },
    },
  })
end

function T.player_house_header_targets_script_000_in_bank_0845()
  local bytes = u16(0x0101)
    .. u16(0)
    .. u16(0)
    .. u16(0x4106)
    .. u16(3)
    .. u16(7)
    .. u16(0x4106)
    .. u16(0)
    .. u16(1)
    .. u16(0)
  local result = assert(ScriptHeader.parse(bytes, { mapId = 63, memberId = 618, scriptBankId = 845 }))
  Assert.equal(result[1].rules[1].scriptId, "vanilla.hgss.scr_seq.0845.script_006")
  Assert.equal(result[1].rules[2].scriptId, "vanilla.hgss.scr_seq.0845.script_000")
end

function T.empty_header_has_an_explicit_empty_rule_set()
  Assert.deepEqual(ScriptHeader.parse("", {}), {})
end

function T.source_no_init_record_is_empty_when_explicitly_allowed()
  local bytes = string.char(3, 2, 0, 0, 0, 0)
  Assert.deepEqual(ScriptHeader.parse(bytes, { scriptBankId = 10 }), {
    { type = "on_resume", scriptId = "vanilla.hgss.scr_seq.0010.script_001" },
  })
end

function T.mixed_stream_preserves_later_on_frame_table()
  local bytes = string.char(3, 2, 0, 0, 0, 1, 3, 0, 0, 0, 0, 0, 0, 0x06, 0x41, 3, 0, 7, 0, 0, 0)
  Assert.deepEqual(ScriptHeader.parse(bytes, { scriptBankId = 845 }), {
    { type = "on_resume", scriptId = "vanilla.hgss.scr_seq.0845.script_001" },
    {
      type = "on_frame_eq",
      rules = {
        { variableId = 0x4106, equals = 3, scriptId = "vanilla.hgss.scr_seq.0845.script_006" },
      },
    },
  })
end

function T.type_one_header_allows_zero_alignment_padding_after_terminator()
  local bytes = u16(0x0101) .. u16(0) .. u16(0) .. u16(0x408C) .. u16(2) .. u16(2) .. u16(0) .. u16(0)
  Assert.equal(#ScriptHeader.parse(bytes, { scriptBankId = 472 })[1].rules, 1)
end

function T.malformed_header_is_rejected()
  Assert.throws(function()
    ScriptHeader.parse("G4IH", { mapId = 1, memberId = 2 })
  end)
end

function T.malformed_typed_entries_use_structured_source_errors()
  local cases = {
    string.char(9),
    string.char(1, 0, 0),
    string.char(2, 1, 0, 1, 0),
    string.char(1, 0, 0, 0, 0),
    string.char(1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0),
  }
  for _, bytes in ipairs(cases) do
    local ok, err = pcall(ScriptHeader.parse, bytes, { mapId = 1, memberId = 2 })
    Assert.isFalse(ok)
    Assert.isTrue(Errors.is(err))
    Assert.equal(err.code, "SCRIPT_HEADER_INVALID")
  end
end

return { tests = T }
