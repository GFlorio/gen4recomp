-- Synthetic encrypted-bank round trips and typed validation errors for the
-- MAT message decoder.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMessageBank = require("romdump.src.digest.ui.FieldMessageBank")

local T = {}

local function bxor(a, b)
  local result = 0
  local bit = 1
  while a > 0 or b > 0 do
    if (a % 2) ~= (b % 2) then
      result = result + bit
    end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return result
end

local function xor32(a, b)
  local lo = bxor(a % 65536, b % 65536)
  local hi = bxor(math.floor(a / 65536) % 65536, math.floor(b / 65536) % 65536)
  return lo + hi * 65536
end

local function returnsCode(code, fn)
  local result, err = fn()
  Assert.isNil(result, "expected a failure result")
  Assert.isTrue(Errors.is(err), "expected a structured error")
  local errorValue = assert(err) --[[@as Errors.Error]]
  Assert.equal(errorValue.code, code)
end

local function decryptRoundTrip(messages, key)
  local bytes = FieldMessageBank.encodeForTests(messages, key)
  local bank = assert(FieldMessageBank.decode(bytes, { label = "fixture-bank" }))
  Assert.equal(bank.messageCount, #messages)
  Assert.equal(bank.key, key)
  for index = 1, #messages do
    Assert.equal(bank.entries[index].length, #messages[index])
    Assert.deepEqual(bank.messages[index].raw, messages[index])
  end
  return bank
end

function T.decrypts_known_synthetic_bank()
  local key = 0x4F2F
  local first = { 0x0141, 0x0153, 0x015B, 0x01AD, 0x01DE, 0xFFFF }
  local second = {
    0x013A,
    0x0156,
    0x0153,
    0x014A,
    0x0149,
    0x0157,
    0x0157,
    0x0153,
    0x0156,
    0x01DE,
    0xFFFE,
    0x0103,
    0x0002,
    0x0000,
    0x0000,
    0xFFFF,
  }
  local bank = decryptRoundTrip({ first, second }, key)
  Assert.equal(bank.tableEnd, 4 + 2 * 8)
  local entry = bank.entries[1]
  Assert.equal(entry.offset, bank.tableEnd)
  Assert.equal(entry.length, #first)
end

function T.seeds_wrap_to_sixteen_bits()
  -- Large keys and many messages must wrap mod 2^16 without losing the XOR
  -- structure (Decrypt1/Decrypt2 use u16 arithmetic in src/msgdata.c).
  local messages = {}
  for i = 1, 40 do
    messages[i] = { 0x0121 + (i % 10), 0xFFFF }
  end
  local bank = decryptRoundTrip(messages, 0xBEEF)
  Assert.equal(bank.messageCount, 40)
  Assert.equal(bank.messages[40].raw[1], 0x0121 + (40 % 10))
end

function T.encrypted_member_round_trip_is_byte_identical()
  local messages = { { 0x0041, 0xFFFF }, { 0x0042, 0x0043, 0xFFFF } }
  local key = 0x1234
  local bytes = FieldMessageBank.encodeForTests(messages, key)
  local bank = assert(FieldMessageBank.decode(bytes, {}))
  local decoded = {}
  for index = 1, bank.messageCount do
    decoded[index] = bank.messages[index].raw
  end
  Assert.equal(FieldMessageBank.encodeForTests(decoded, key), bytes)
end

function T.header_truncated_is_typed()
  returnsCode("MESSAGE_HEADER_TRUNCATED", function()
    return FieldMessageBank.decode("\0\1")
  end)
end

function T.count_beyond_maximum_is_typed()
  local bytes = string.char(0xFF, 0x7F, 0x01, 0x00) -- count 0x7FFF
  returnsCode("MESSAGE_COUNT_INVALID", function()
    return FieldMessageBank.decode(bytes)
  end)
end

function T.table_past_member_end_is_typed()
  -- count 3 but the member ends inside the entry table.
  local bytes = string.char(3, 0, 0xAB, 0xCD) .. string.rep("\0", 4 + 3 * 8 - 4 - 1)
  returnsCode("MESSAGE_TABLE_OUT_OF_BOUNDS", function()
    return FieldMessageBank.decode(bytes)
  end)
end

function T.corrupt_entry_offsets_are_typed()
  -- Re-encrypt a valid entry with an out-of-bounds offset.
  local key = 0x1234
  local bytes = FieldMessageBank.encodeForTests({ { 0x0041, 0xFFFF } }, key)
  local seed16 = ((key * 765) % 65536) % 65536
  local seed32 = seed16 + seed16 * 65536
  local badOffset = 4 + 8 + 4000
  local encBad = xor32(badOffset, seed32)
  local corrupted = bytes:sub(1, 3)
    .. string.char(
      encBad % 256,
      math.floor(encBad / 256) % 256,
      math.floor(encBad / 65536) % 256,
      math.floor(encBad / 16777216) % 256
    )
    .. bytes:sub(9)
  returnsCode("MESSAGE_ENTRY_OUT_OF_BOUNDS", function()
    return FieldMessageBank.decode(corrupted, {})
  end)
end

function T.unaligned_and_zero_length_entries_are_typed()
  -- Plaintext table (key 0 gives seed 0 for entry 0): offset 1 is unaligned.
  local badOffset = 1
  local encBad = xor32(badOffset, 0)
  local bytes = string.char(1, 0, 0, 0)
    .. string.char(
      encBad % 256,
      math.floor(encBad / 256) % 256,
      math.floor(encBad / 65536) % 256,
      math.floor(encBad / 16777216) % 256,
      0,
      0,
      0,
      0
    )
  returnsCode("MESSAGE_ENTRY_OUT_OF_BOUNDS", function()
    return FieldMessageBank.decode(bytes, {})
  end)
end

function T.overlapping_entries_are_typed()
  -- Two entries pointing at the same decrypted region. The entries must be
  -- encrypted individually (each entry uses its own index seed), so entry 1
  -- is re-encrypted from the same plaintext offset/length as entry 0.
  local key = 0x2222
  local bytes = FieldMessageBank.encodeForTests({ { 0x0041, 0x0042, 0xFFFF }, { 0x0043, 0xFFFF } }, key)
  local entry0 = bytes:sub(5, 12)
  local offset = 4 + 2 * 8
  local length = 3
  local seed16 = ((key * 765 * 2) % 65536) % 65536
  local seed32 = seed16 + seed16 * 65536
  local encOffset = xor32(offset, seed32)
  local encLength = xor32(length, seed32)
  local entry1 = string.char(
    encOffset % 256,
    math.floor(encOffset / 256) % 256,
    math.floor(encOffset / 65536) % 256,
    math.floor(encOffset / 16777216) % 256,
    encLength % 256,
    math.floor(encLength / 256) % 256,
    math.floor(encLength / 65536) % 256,
    math.floor(encLength / 16777216) % 256
  )
  local corrupted = bytes:sub(1, 4) .. entry0 .. entry1 .. bytes:sub(21)
  returnsCode("MESSAGE_ENTRY_OVERLAP", function()
    return FieldMessageBank.decode(corrupted, {})
  end)
end

function T.missing_eos_is_typed()
  -- A hand-encrypted single message without the EOS terminator.
  local key = 0x3333
  local seed = ((1 * 596947) % 65536) % 65536
  local units = { 0x0041, 0x0042 }
  local bytes = {}
  for i = 1, #units do
    local encrypted = bxor(units[i], seed)
    bytes[i] = string.char(encrypted % 256, math.floor(encrypted / 256))
    seed = (seed + 18749) % 65536
  end
  local seed16 = ((key * 765) % 65536) % 65536
  local seed32 = seed16 + seed16 * 65536
  local offset = 4 + 8
  local length = 2
  local encOffset = xor32(offset, seed32)
  local encLength = xor32(length, seed32)
  local member = string.char(1, 0, key % 256, math.floor(key / 256))
    .. string.char(
      encOffset % 256,
      math.floor(encOffset / 256) % 256,
      math.floor(encOffset / 65536) % 256,
      math.floor(encOffset / 16777216) % 256,
      encLength % 256,
      math.floor(encLength / 256) % 256,
      math.floor(encLength / 65536) % 256,
      math.floor(encLength / 16777216) % 256
    )
    .. table.concat(bytes)
  returnsCode("MESSAGE_EOS_MISSING", function()
    return FieldMessageBank.decode(member, {})
  end)
end

return { tests = T }
