-- Bounds-checked, zero-based reader over a binary string. Pure domain module:
-- no love dependency. Little-endian integers are assembled arithmetically,
-- which is exact for 8/16/32-bit values under LuaJIT doubles.

local Errors = require("libs.rom.src.Errors")

---@class BinaryReader
---@field private _data string
---@field private _name string
---@field data string
---@field label string?
---@field length fun(self: BinaryReader): integer
---@field assertRange fun(self: BinaryReader, offset: integer, length: integer, fieldName: string): boolean
---@field u8 fun(self: BinaryReader, offset: integer): integer
---@field u16le fun(self: BinaryReader, offset: integer): integer
---@field u32le fun(self: BinaryReader, offset: integer): integer
---@field f32le fun(self: BinaryReader, offset: integer): number
---@field bytes fun(self: BinaryReader, offset: integer, length: integer): string
---@field ascii fun(self: BinaryReader, offset: integer, length: integer, trimNul: boolean?): string
---@field slice fun(self: BinaryReader, offset: integer, length: integer, label: string?): BinaryReader
local BinaryReader = {}
BinaryReader.__index = BinaryReader

function BinaryReader.new(data, label)
  assert(type(data) == "string", "BinaryReader requires a string")
  return setmetatable({ data = data, label = label or "binary" }, BinaryReader)
end

function BinaryReader:length()
  return #self.data
end

function BinaryReader:assertRange(offset, length, fieldName)
  if
    type(offset) ~= "number"
    or offset < 0
    or type(length) ~= "number"
    or length < 0
    or offset + length > #self.data
  then
    Errors.raise(
      "READ_OUT_OF_BOUNDS",
      string.format(
        "%s: read of %s bytes at offset %s exceeds %d-byte %s",
        fieldName or "read",
        tostring(length),
        tostring(offset),
        #self.data,
        self.label
      ),
      { offset = offset, length = length, available = #self.data, field = fieldName }
    )
  end
  return true
end

function BinaryReader:u8(offset)
  self:assertRange(offset, 1, "u8")
  return string.byte(self.data, offset + 1)
end

function BinaryReader:u16le(offset)
  self:assertRange(offset, 2, "u16le")
  local b0, b1 = string.byte(self.data, offset + 1, offset + 2)
  return b0 + b1 * 256
end

function BinaryReader:u32le(offset)
  self:assertRange(offset, 4, "u32le")
  local b0, b1, b2, b3 = string.byte(self.data, offset + 1, offset + 4)
  return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

-- IEEE-754 binary32, little-endian (mirror of BinaryWriter:f32).
function BinaryReader:f32le(offset)
  self:assertRange(offset, 4, "f32le")
  local b0, b1, b2, b3 = string.byte(self.data, offset + 1, offset + 4)
  local word = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
  local sign = math.floor(word / 2147483648) % 2
  local biased = math.floor(word / 8388608) % 256
  local mantissa = word % 8388608
  local value
  if biased == 0 then
    value = mantissa == 0 and 0 or (mantissa / 8388608) * 2 ^ -126
  elseif biased == 255 then
    value = mantissa == 0 and math.huge or (0 / 0)
  else
    value = (1 + mantissa / 8388608) * 2 ^ (biased - 127)
  end
  if sign == 1 then
    value = -value
  end
  return value
end

function BinaryReader:bytes(offset, length)
  self:assertRange(offset, length, "bytes")
  return string.sub(self.data, offset + 1, offset + length)
end

function BinaryReader:ascii(offset, length, trimNul)
  local s = self:bytes(offset, length)
  if trimNul then
    local nul = string.find(s, "\0", 1, true)
    if nul then
      s = string.sub(s, 1, nul - 1)
    end
  end
  return s
end

function BinaryReader:slice(offset, length, label)
  return BinaryReader.new(self:bytes(offset, length), label or self.label)
end

function BinaryReader:remaining(offset)
  self:assertRange(offset, 0, "remaining")
  return #self.data - offset
end

return BinaryReader
