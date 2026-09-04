-- Bounded decoder for the NNS SWAR wave-archive container: a u32 wave count
-- at 0x38 and u32 member offsets at 0x3C (absolute from the SWAR start, per
-- GBATEK "DS Sound Files - SWAR" and the SNDWaveArc struct), where each
-- member is a 12-byte SNDWaveParam followed by sample data. Members are
-- sliced on demand; every offset and extent is bounds-checked. Pure domain
-- module.

local Errors = require("libs.errors.src.Errors")

local Swar = {}

Swar.__index = Swar

local function fail(code, message, context)
  Errors.raise(code, message, context)
end

local function u32At(bytes, offset, _)
  return string.byte(bytes, offset + 1)
    + string.byte(bytes, offset + 2) * 256
    + string.byte(bytes, offset + 3) * 65536
    + string.byte(bytes, offset + 4) * 16777216
end

local function _decode(bytes, context)
  local source = context or "SWAR"
  local size = #bytes
  if size < 0x3C then
    fail("SWAR_TRUNCATED", "wave archive is shorter than its member table header", {
      source = source,
      actual = size,
    })
  end
  local waveCount = u32At(bytes, 0x38, source)
  local tableEnd = 0x3C + waveCount * 4
  if tableEnd > size then
    fail("SWAR_TRUNCATED", "member offset table extends past the end of the wave archive", {
      source = source,
      waveCount = waveCount,
    })
  end
  local members = {}
  for memberId = 0, waveCount - 1 do
    local offset = u32At(bytes, 0x3C + memberId * 4, source)
    local nextOffset = memberId + 1 < waveCount and u32At(bytes, 0x40 + memberId * 4, source) or size
    if offset < tableEnd or offset + 12 > size or nextOffset < offset or nextOffset > size then
      fail("SWAR_TRUNCATED", "member range lies outside the wave archive", {
        source = source,
        memberId = memberId,
        offset = offset,
        nextOffset = nextOffset,
        size = size,
      })
    end
    members[memberId] = { offset = offset, size = nextOffset - offset }
  end
  return setmetatable({ source = source, waveCount = waveCount, members = members, _bytes = bytes }, Swar)
end

---@param bytes string
---@param context string?
---@return table<string, unknown>?|nil
---@return Errors.Error?|nil
function Swar.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

---@param memberId integer
---@return string?|nil
---@return Errors.Error?|nil
function Swar:readMember(memberId)
  local entry = self.members[memberId]
  if entry == nil then
    return nil,
      Errors.new("SWAR_MEMBER_OUT_OF_RANGE", "no wave member " .. tostring(memberId), {
        source = self.source,
        memberId = memberId,
        waveCount = self.waveCount,
      })
  end
  return string.sub(self._bytes, entry.offset + 1, entry.offset + entry.size)
end

return Swar
