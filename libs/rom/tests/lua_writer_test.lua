local Assert = require("tests.support.Assert")
local LuaWriter = require("libs.rom.src.LuaWriter")

local function roundTrip(value)
  local src = LuaWriter.encode(value)
  local chunk = assert(loadstring(src))
  return chunk(), src
end

local T = {}

function T.round_trips_scalars_and_nesting()
  local value = {
    schema = 1,
    version = "heartgold",
    ratio = -3,
    ok = true,
    off = false,
    arm9 = { offset = 0, size = 4096 },
  }
  local out = roundTrip(value)
  Assert.deepEqual(out, value)
end

-- Zero-based FAT keys are the whole point.
function T.round_trips_zero_based_numeric_keys()
  local value = { [0] = "a", [1] = "b", [2] = "c" }
  local out = roundTrip(value)
  Assert.equal(out[0], "a")
  Assert.equal(out[1], "b")
  Assert.equal(out[2], "c")
end

function T.round_trips_strings_with_special_characters()
  local value = {
    path = "a/0/4/1",
    weird = "tab\tnul\0end",
    quote = 'he said "hi"',
    backslash = "a\\b\\c",
    newline = "line1\nline2",
    cr = "cr\rreturn",
    tab = "col1\tcol2",
  }
  local out = roundTrip(value)
  Assert.deepEqual(out, value)
end

-- A variable-width decimal escape (e.g. `\1` followed by the characters "23")
-- would parse as one `\123` byte, so every escaped control byte must be
-- exactly three digits wide.
function T.decimal_escapes_never_absorb_following_digits()
  for b = 0, 31 do
    for d = 0, 9 do
      local value = string.char(b) .. tostring(d)
      local out = roundTrip(value)
      Assert.equal(out, value, string.format("byte %d followed by digit %d", b, d))
    end
  end
  for d = 0, 9 do
    local value = string.char(127) .. tostring(d)
    local out = roundTrip(value)
    Assert.equal(out, value, string.format("byte 127 followed by digit %d", d))
  end
end

function T.output_is_deterministic_and_key_sorted()
  local a = LuaWriter.encode({ b = 1, a = 2, c = 3 })
  local b = LuaWriter.encode({ c = 3, a = 2, b = 1 })
  Assert.equal(a, b)
  Assert.isTrue(a:find("a", 1, true) < a:find("b", 1, true))
  Assert.isTrue(a:find("b", 1, true) < a:find("c", 1, true))
end

function T.rejects_function_values()
  local err = Assert.throws(function()
    LuaWriter.encode({ f = function() end })
  end)
  Assert.isTrue(tostring(err):lower():find("function", 1, true) ~= nil)
end

function T.rejects_cyclic_tables()
  local t = {}
  t.self = t
  local err = Assert.throws(function()
    LuaWriter.encode(t)
  end)
  Assert.isTrue(tostring(err):lower():find("cycl", 1, true) ~= nil)
end

return T
