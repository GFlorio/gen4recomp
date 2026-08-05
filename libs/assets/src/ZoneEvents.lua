-- Decodes an HGSS zone-event NARC member into complete background, object,
-- warp, and coordinate event records. The binary layout follows
-- pret/pokeheartgold's fielddata event structures. This pure module performs
-- checked, zero-based little-endian reads and preserves every source value.

local BinaryReader = require("libs.rom.src.BinaryReader")
local Errors = require("libs.rom.src.Errors")

local ZoneEvents = {}

local RECORD_SIZE = {
  backgroundEvents = 20,
  objectEvents = 32,
  warps = 12,
  coordinateEvents = 16,
}

local DIRECTIONS = {
  [0] = "north",
  [1] = "south",
  [2] = "west",
  [3] = "east",
}

local function s16(value)
  return value >= 0x8000 and value - 0x10000 or value
end

local function s32(value)
  return value >= 0x80000000 and value - 0x100000000 or value
end

local function need(reader, offset, length, category, recordIndex)
  if offset + length <= reader:length() then return end
  Errors.raise("ZONE_EVENTS_TRUNCATED",
    string.format("%s record %s at offset %d needs %d bytes, only %d remain",
      category, tostring(recordIndex), offset, length, math.max(0, reader:length() - offset)),
    { sourceOffset = offset, requiredBytes = length,
      availableBytes = math.max(0, reader:length() - offset),
      category = category, recordIndex = recordIndex })
end

local function readCount(reader, offset, category)
  need(reader, offset, 4, category, nil)
  return reader:u32le(offset), offset + 4
end

local function ensureRecords(reader, offset, count, category)
  local size = RECORD_SIZE[category]
  -- u32 counts cannot overflow Lua's exact-integer range at these record sizes,
  -- but retain the explicit invariant at this untrusted-input boundary.
  if count > math.floor(9007199254740991 / size) then
    Errors.raise("ZONE_EVENTS_COUNT_INVALID",
      category .. " count cannot be represented safely: " .. count,
      { sourceOffset = offset - 4, category = category, count = count, recordSize = size })
  end
  local available = reader:length() - offset
  local required = count * size
  if required <= available then return end
  local recordIndex = math.floor(math.max(0, available) / size)
  need(reader, offset + recordIndex * size, size, category, recordIndex)
end

local function decodeBackground(reader, offset, index)
  local directionRaw = reader:u32le(offset + 16)
  return {
    index = index,
    scriptId = reader:u16le(offset),
    type = reader:u16le(offset + 2),
    x = s32(reader:u32le(offset + 4)),
    z = s32(reader:u32le(offset + 8)),
    y = s32(reader:u32le(offset + 12)),
    directionRaw = directionRaw,
    direction = DIRECTIONS[directionRaw] or "unknown",
  }
end

local function decodeObject(reader, offset, index)
  local facingDirectionRaw = s16(reader:u16le(offset + 12))
  return {
    index = index,
    objectEventId = reader:u16le(offset),
    spriteId = reader:u16le(offset + 2),
    movement = reader:u16le(offset + 4),
    type = reader:u16le(offset + 6),
    eventFlag = reader:u16le(offset + 8),
    scriptId = reader:u16le(offset + 10),
    facingDirectionRaw = facingDirectionRaw,
    facingDirection = DIRECTIONS[facingDirectionRaw] or "unknown",
    param0 = reader:u16le(offset + 14),
    param1 = reader:u16le(offset + 16),
    param2 = reader:u16le(offset + 18),
    xRange = s16(reader:u16le(offset + 20)),
    yRange = s16(reader:u16le(offset + 22)),
    x = reader:u16le(offset + 24),
    z = reader:u16le(offset + 26),
    y = s32(reader:u32le(offset + 28)),
  }
end

local function decodeWarp(reader, offset, index)
  return {
    index = index,
    x = reader:u16le(offset),
    z = reader:u16le(offset + 2),
    destinationMapId = reader:u16le(offset + 4),
    destinationWarpId = reader:u16le(offset + 6),
    y = reader:u32le(offset + 8),
  }
end

local function decodeCoordinate(reader, offset, index)
  return {
    index = index,
    scriptId = reader:u16le(offset),
    x = s16(reader:u16le(offset + 2)),
    z = s16(reader:u16le(offset + 4)),
    width = reader:u16le(offset + 6),
    height = reader:u16le(offset + 8),
    y = reader:u16le(offset + 10),
    requiredValue = reader:u16le(offset + 12),
    variableId = reader:u16le(offset + 14),
  }
end

local function decodeCategory(reader, offset, category, decodeRecord)
  local count
  count, offset = readCount(reader, offset, category)
  ensureRecords(reader, offset, count, category)
  local records = {}
  local size = RECORD_SIZE[category]
  for index = 0, count - 1 do
    records[#records + 1] = decodeRecord(reader, offset, index)
    offset = offset + size
  end
  return records, offset
end

local function _decode(bytes, opts)
  opts = opts or {}
  local reader = BinaryReader.new(bytes, opts.source or "HGSS zone events")
  local offset = 0
  local backgroundEvents, objectEvents, warps, coordinateEvents
  backgroundEvents, offset = decodeCategory(reader, offset, "backgroundEvents", decodeBackground)
  objectEvents, offset = decodeCategory(reader, offset, "objectEvents", decodeObject)
  warps, offset = decodeCategory(reader, offset, "warps", decodeWarp)
  coordinateEvents, offset = decodeCategory(reader, offset, "coordinateEvents", decodeCoordinate)

  local trailingBytes
  if offset ~= reader:length() then
    if not opts.allowTrailingBytes then
      Errors.raise("ZONE_EVENTS_TRAILING_BYTES",
        string.format("%d trailing bytes at offset %d", reader:length() - offset, offset),
        { sourceOffset = offset, trailingByteCount = reader:length() - offset })
    end
    trailingBytes = reader:bytes(offset, reader:length() - offset)
  end

  return {
    schema = "hgss-zone-events-v1",
    mapId = opts.mapId,
    eventMemberId = opts.eventMemberId,
    backgroundEvents = backgroundEvents,
    objectEvents = objectEvents,
    warps = warps,
    coordinateEvents = coordinateEvents,
    byteLength = reader:length(),
    consumedBytes = offset,
    trailingBytes = trailingBytes,
  }
end

function ZoneEvents.decode(bytes, opts)
  assert(type(bytes) == "string", "decode requires member bytes")
  local ok, result = pcall(_decode, bytes, opts)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return ZoneEvents
