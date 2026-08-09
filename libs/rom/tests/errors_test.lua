local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")

local T = {}

function T.new_carries_code_message_context()
  local e = Errors.new("BAD", "it broke", { fileId = 17 })
  Assert.equal(e.code, "BAD")
  Assert.equal(e.message, "it broke")
  Assert.equal(e.context.fileId, 17)
end

function T.new_allows_missing_context()
  local e = Errors.new("BAD", "it broke")
  Assert.deepEqual(e.context, {})
end

function T.is_recognizes_error_objects()
  Assert.isTrue(Errors.is(Errors.new("X", "y")))
  Assert.isFalse(Errors.is("plain string"))
  Assert.isFalse(Errors.is({ code = "X", message = "y" }))
  Assert.isFalse(Errors.is(nil))
end

function T.format_includes_code_and_message()
  local s = Errors.format(Errors.new("FAT_RANGE", "past the ROM"))
  Assert.isTrue(s:find("FAT_RANGE", 1, true) ~= nil)
  Assert.isTrue(s:find("past the ROM", 1, true) ~= nil)
end

function T.format_tolerates_non_error_values()
  Assert.equal(Errors.format("just a string"), "just a string")
end

function T.format_emits_nested_context_in_stable_key_order()
  Assert.equal(
    Errors.format(Errors.new("BAD", "broken", {
      z = 2,
      context = { role = "building", mapId = 4 },
      a = 1,
    })),
    "BAD: broken {a=1,context={mapId=4,role=building},z=2}"
  )
end

-- Structured errors must survive pcall unchanged.
function T.raise_survives_pcall()
  local ok, err = pcall(function()
    Errors.raise("SHORT_HEADER", "too small", { size = 10 })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "SHORT_HEADER")
  Assert.equal(assert(err).context.size, 10)
end

return T
