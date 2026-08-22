local Assert = require("tests.support.Assert")
local ScriptHeader = require("romdump.src.digest.ScriptHeader")

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
        { variableId = 0x4106, equals = 3, scriptIndex = 6, scriptId = "vanilla.hgss.scr_seq.0845.script_006" },
        { variableId = 0x4106, equals = 0, scriptIndex = 0, scriptId = "vanilla.hgss.scr_seq.0845.script_000" },
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
  Assert.deepEqual(
    ScriptHeader.parse(string.char(0x02, 0x01, 0x00, 0x00, 0x00, 0x04, 0x02, 0x00), { allowNoInit = true }),
    {}
  )
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

return { tests = T }
