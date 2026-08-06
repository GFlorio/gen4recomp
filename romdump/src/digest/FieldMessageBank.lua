-- Import-time decoder for one HGSS msgdata member (MAT table): validates the
-- container and produces decrypted message code-unit arrays for the tokenizer
-- (romdump digester; the runtime never sees raw ROM bytes). The container and
-- both decryption stages follow `src/msgdata.c` in the pinned
-- pret/pokeheartgold checkout (Decrypt1/Decrypt2, ReadMsgData_NewNarc_*); the
-- MAT_ENTRY struct shape is `include/msgdata.h`. Pure module: BinaryReader and
-- Errors only, no love dependency.

local BinaryReader = require("libs.rom.src.BinaryReader")
local Errors = require("libs.rom.src.Errors")

local FieldMessageBank = {}

-- Spec section 7.5: decrypted table entry offset/length keyed by entry index.
FieldMessageBank.DECRYPT1_SEED = 765
FieldMessageBank.DECRYPT2_SEED = 596947
FieldMessageBank.DECRYPT2_STEP = 18749

local DEFAULT_MAX_MESSAGES = 4096

local function mulmod(a, b)
  return (a * b) % 65536
end

local function bxor(a, b)
  local result = 0
  local bit = 1
  while a > 0 or b > 0 do
    if (a % 2) ~= (b % 2) then result = result + bit end
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    bit = bit * 2
  end
  return result
end

local function xor32(a, b)
  -- 32-bit XOR via 16-bit halves: seed32 is (s16 | s16 << 16) by construction,
  -- so the halves never carry between each other.
  local lo = bxor(a % 65536, b % 65536)
  local hi = bxor(math.floor(a / 65536) % 65536, math.floor(b / 65536) % 65536)
  return lo + hi * 65536
end

local function decryptEntry(reader, key, index)
  local base = 4 + index * 8
  local encryptedOffset = reader:u32le(base)
  local encryptedLength = reader:u32le(base + 4)
  local seed16 = mulmod(mulmod(key, FieldMessageBank.DECRYPT1_SEED), index + 1)
  local seed32 = seed16 + seed16 * 65536
  return xor32(encryptedOffset, seed32), xor32(encryptedLength, seed32)
end

local function decryptText(reader, offset, length, index)
  local seed = mulmod(FieldMessageBank.DECRYPT2_SEED, index + 1)
  local units = {}
  for i = 0, length - 1 do
    local encrypted = reader:u16le(offset + i * 2)
    units[i + 1] = bxor(encrypted, seed)
    seed = (seed + FieldMessageBank.DECRYPT2_STEP) % 65536
  end
  return units
end

local function _decode(data, opts)
  opts = opts or {}
  local label = opts.label or "msgdata-member"
  local maxMessages = opts.maxMessages or DEFAULT_MAX_MESSAGES
  local reader = BinaryReader.new(data, label)
  local size = reader:length()

  if size < 4 then
    Errors.raise("MESSAGE_HEADER_TRUNCATED",
      label .. " is " .. size .. " bytes, need at least a 4-byte MAT header",
      { size = size })
  end

  local messageCount = reader:u16le(0)
  local key = reader:u16le(2)
  if messageCount > maxMessages then
    Errors.raise("MESSAGE_COUNT_INVALID",
      "message count " .. messageCount .. " exceeds configured maximum " .. maxMessages,
      { messageCount = messageCount, maxMessages = maxMessages })
  end

  local tableEnd = 4 + messageCount * 8
  if tableEnd > size then
    Errors.raise("MESSAGE_TABLE_OUT_OF_BOUNDS",
      "entry table ends at " .. tableEnd .. " but member is " .. size .. " bytes",
      { tableEnd = tableEnd, size = size, messageCount = messageCount })
  end

  local entries = {}
  for index = 0, messageCount - 1 do
    local offset, length = decryptEntry(reader, key, index)
    if offset % 2 ~= 0 then
      Errors.raise("MESSAGE_ENTRY_OUT_OF_BOUNDS",
        "message " .. index .. " offset " .. offset .. " is not u16 aligned",
        { messageId = index, offset = offset })
    end
    if length == 0 then
      Errors.raise("MESSAGE_ENTRY_OUT_OF_BOUNDS",
        "message " .. index .. " has zero length",
        { messageId = index })
    end
    if offset < tableEnd or offset + length * 2 > size then
      Errors.raise("MESSAGE_ENTRY_OUT_OF_BOUNDS",
        "message " .. index .. " region [" .. offset .. ", " .. offset + length * 2
          .. ") is outside the member body [" .. tableEnd .. ", " .. size .. ")",
        { messageId = index, offset = offset, length = length, tableEnd = tableEnd, size = size })
    end
    entries[index + 1] = { messageId = index, offset = offset, length = length }
  end

  for a = 1, messageCount do
    for b = a + 1, messageCount do
      local ea, eb = entries[a], entries[b]
      local aEnd = ea.offset + ea.length * 2
      local bEnd = eb.offset + eb.length * 2
      local overlap = not (aEnd <= eb.offset or bEnd <= ea.offset)
      if overlap then
        Errors.raise("MESSAGE_ENTRY_OVERLAP",
          "messages " .. ea.messageId .. " and " .. eb.messageId .. " overlap; "
            .. "shared regions must be verified before they are allowed",
          { first = { messageId = ea.messageId, offset = ea.offset, length = ea.length },
            second = { messageId = eb.messageId, offset = eb.offset, length = eb.length } })
      end
    end
  end

  local messages = {}
  for index = 0, messageCount - 1 do
    local entry = entries[index + 1]
    local units = decryptText(reader, entry.offset, entry.length, index)
    if units[#units] ~= 0xFFFF then
      Errors.raise("MESSAGE_EOS_MISSING",
        "message " .. index .. " does not terminate with EOS (0xFFFF)",
        { messageId = index, lastUnit = units[#units] })
    end
    messages[index + 1] = {
      messageId = index,
      raw = units,
      length = entry.length,
    }
  end

  return {
    messageCount = messageCount,
    key = key,
    tableEnd = tableEnd,
    entries = entries,
    messages = messages,
  }
end

function FieldMessageBank.decode(data, opts)
  assert(type(data) == "string", "FieldMessageBank.decode requires a string")
  local ok, result = pcall(_decode, data, opts)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

-- Inverse of decode for test fixtures only: encrypts authored plaintext code
-- units into a byte-identical MAT member. Never used by production compilers.
function FieldMessageBank.encodeForTests(messages, key)
  assert(type(messages) == "table" and type(key) == "number", "encodeForTests(messages, key)")
  local body = {}
  local base = 4 + #messages * 8
  local cursor = base
  local tableBytes = {}
  tableBytes[1] = string.char(#messages % 256, math.floor(#messages / 256))
  tableBytes[2] = string.char(key % 256, math.floor(key / 256))
  for index = 1, #messages do
    local units = messages[index]
    assert(units[#units] == 0xFFFF, "test message must end with EOS")
    local offset = cursor
    local length = #units
    local seed16 = mulmod(mulmod(key, FieldMessageBank.DECRYPT1_SEED), index)
    local seed32 = seed16 + seed16 * 65536
    local encryptedOffset = xor32(offset, seed32)
    local encryptedLength = xor32(length, seed32)
    local entry = string.char(
      encryptedOffset % 256, math.floor(encryptedOffset / 256) % 256,
      math.floor(encryptedOffset / 65536) % 256, math.floor(encryptedOffset / 16777216) % 256,
      encryptedLength % 256, math.floor(encryptedLength / 256) % 256,
      math.floor(encryptedLength / 65536) % 256, math.floor(encryptedLength / 16777216) % 256)
    tableBytes[#tableBytes + 1] = entry
    local seed = mulmod(FieldMessageBank.DECRYPT2_SEED, index)
    local bytes = {}
    for i = 1, length do
      local encrypted = bxor(units[i], seed)
      bytes[i] = string.char(encrypted % 256, math.floor(encrypted / 256))
      seed = (seed + FieldMessageBank.DECRYPT2_STEP) % 65536
    end
    body[#body + 1] = table.concat(bytes)
    cursor = cursor + length * 2
  end
  return table.concat(tableBytes) .. table.concat(body)
end

return FieldMessageBank
