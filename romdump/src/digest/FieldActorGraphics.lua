-- Decoder for the four field-actor tables that live in HGSS overlay 1. Pure
-- domain module: it takes the decompressed overlay bytes plus the load address
-- the ROM's overlay table reported, and turns every original runtime address in
-- the locator manifest into an overlay offset.
--
-- The tables, in the order the original loader consults them:
--
--   graphics     six-byte records `u16 spriteId, u16 mapModelId, u16 packed`,
--                scanned linearly to a `spriteId == 0xFFFF` terminator by
--                ObjectEvent_GetGraphicsInfo (asm/overlay_01_021F8D80.s).
--   descriptors  24 eight-byte visual descriptors indexed by packed bits 10-15;
--                `+2` is a shared-model key, `+3` a timeline key, and `+4` a
--                pointer to that descriptor's animation-range table
--                (asm/overlay_01_021F944C.s).
--   modelKeys    flat u16 (key, mmodel memberId) pairs, terminated by key 255.
--   timelineKeys the same shape for the timeline `.bin` members.
--
-- An animation-range record is `s32 startFrame, s32 endFrame, s32 endMode`
-- (asm/unk_02023694.s); `endMode == 0` wraps and non-zero clamps. The array is
-- terminated by a `[0, 0, 2]` record, so the per-descriptor range count is read
-- from the data rather than assumed. Ranges are indexed by
-- the global_fieldmap.h direction order north, south, west, east; a descriptor
-- with eight ranges carries a second directional set.
--
-- The packed word is fully partitioned, with no unclassified bits:
--   bits 0-4   movement/terrain profile   (behavior, not an asset selector)
--   bits 5-9   map-object callback family (behavior, not an asset selector)
--   bits 10-15 visual descriptor index    (the asset selector)

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local FieldActorGraphics = {}

local RECORD_SIZE = 6
local DESCRIPTOR_SIZE = 8
local RANGE_SIZE = 12
local KEY_TERMINATOR = 255
local TERMINATOR_SPRITE_ID = 0xFFFF
local MAX_RECORDS = 4096
local MAX_RANGES = 32
local RANGE_TERMINATOR_END_MODE = 2

local function raise(code, message, context)
  Errors.raise(code, message, context or {})
end

-- Convert an original runtime address to an offset inside the loaded overlay.
local function offsetFor(locator, address, label)
  local offset = address - locator.ramAddress
  if offset < 0 or offset >= locator.size then
    raise(
      "FIELD_ACTOR_ADDRESS_OUT_OF_OVERLAY",
      string.format(
        "%s address 0x%08X is outside the overlay loaded at 0x%08X (%d bytes)",
        label,
        address,
        locator.ramAddress,
        locator.size
      ),
      { label = label, address = address, ramAddress = locator.ramAddress, size = locator.size }
    )
  end
  return offset
end

local function splitPacked(packed)
  return {
    movementProfile = packed % 32,
    actorFamily = math.floor(packed / 32) % 32,
    visualDescriptor = math.floor(packed / 1024),
  }
end

FieldActorGraphics.splitPacked = splitPacked

local function decodeRecords(reader, locator, tables)
  local base = offsetFor(locator, tables.graphics.address, "graphics table")
  local records, bySpriteId = {}, {}
  local offset = base

  while true do
    if offset + RECORD_SIZE > locator.size then
      raise(
        "FIELD_ACTOR_TABLE_UNTERMINATED",
        "graphics table ran past the end of the overlay without a 0xFFFF terminator",
        { offset = offset, size = locator.size }
      )
    end
    local spriteId = reader:u16le(offset)
    if spriteId == TERMINATOR_SPRITE_ID then
      break
    end
    if bySpriteId[spriteId] then
      raise(
        "FIELD_ACTOR_DUPLICATE_SPRITE_ID",
        "spriteId " .. spriteId .. " appears more than once in the graphics table",
        { spriteId = spriteId, offset = offset, firstOffset = bySpriteId[spriteId].offset }
      )
    end
    local packed = reader:u16le(offset + 4)
    local fields = splitPacked(packed)
    local record = {
      spriteId = spriteId,
      mapModelId = reader:u16le(offset + 2),
      packed = packed,
      movementProfile = fields.movementProfile,
      actorFamily = fields.actorFamily,
      visualDescriptor = fields.visualDescriptor,
      offset = offset - base,
    }
    records[#records + 1] = record
    bySpriteId[spriteId] = record
    offset = offset + RECORD_SIZE
    if #records > MAX_RECORDS then
      raise(
        "FIELD_ACTOR_TABLE_TOO_LARGE",
        "graphics table exceeded the " .. MAX_RECORDS .. "-record safety limit",
        { limit = MAX_RECORDS }
      )
    end
  end

  local terminatorOffset = offset - base
  local expectedCount = tables.graphics.expectedRecordCount
  if expectedCount and #records ~= expectedCount then
    raise(
      "FIELD_ACTOR_RECORD_COUNT_MISMATCH",
      "graphics table has " .. #records .. " records, expected " .. expectedCount,
      { actual = #records, expected = expectedCount }
    )
  end
  local expectedTerminator = tables.graphics.expectedTerminatorOffset
  if expectedTerminator and terminatorOffset ~= expectedTerminator then
    raise(
      "FIELD_ACTOR_TERMINATOR_MISPLACED",
      string.format("graphics terminator sits at 0x%X, expected 0x%X", terminatorOffset, expectedTerminator),
      { actual = terminatorOffset, expected = expectedTerminator }
    )
  end

  return {
    records = records,
    bySpriteId = bySpriteId,
    tableOffset = base,
    terminatorOffset = terminatorOffset,
    spanBytes = terminatorOffset + RECORD_SIZE,
  }
end

local function decodeKeyTable(reader, locator, address, label)
  local offset = offsetFor(locator, address, label)
  local byKey, order = {}, {}
  while true do
    if offset + 4 > locator.size then
      raise(
        "FIELD_ACTOR_KEY_TABLE_UNTERMINATED",
        label .. " ran past the end of the overlay without a key-255 terminator",
        { label = label, offset = offset }
      )
    end
    local key = reader:u16le(offset)
    if key == KEY_TERMINATOR then
      break
    end
    if byKey[key] then
      raise("FIELD_ACTOR_DUPLICATE_KEY", label .. " defines key " .. key .. " twice", { label = label, key = key })
    end
    byKey[key] = reader:u16le(offset + 2)
    order[#order + 1] = key
    offset = offset + 4
    if #order > MAX_RECORDS then
      raise(
        "FIELD_ACTOR_KEY_TABLE_TOO_LARGE",
        label .. " exceeded its safety limit",
        { label = label, limit = MAX_RECORDS }
      )
    end
  end
  return { byKey = byKey, order = order }
end

local function decodeRanges(reader, locator, address, descriptorIndex)
  local offset = offsetFor(locator, address, "animation range table")
  local ranges = {}
  while true do
    if offset + RANGE_SIZE > locator.size then
      raise(
        "FIELD_ACTOR_RANGES_UNTERMINATED",
        "animation ranges for descriptor " .. descriptorIndex .. " ran past the overlay",
        { descriptor = descriptorIndex, offset = offset }
      )
    end
    local startFrame = reader:u32le(offset)
    local endFrame = reader:u32le(offset + 4)
    local endMode = reader:u32le(offset + 8)
    -- Every range array in the ROM ends with exactly this record. A zero-length
    -- range is otherwise legitimate -- descriptor 21 opens with [0, 0, 0] -- so
    -- the end mode is part of the terminator, not just the frame bounds.
    if startFrame == 0 and endFrame == 0 and endMode == RANGE_TERMINATOR_END_MODE then
      break
    end
    if endFrame < startFrame then
      raise(
        "FIELD_ACTOR_RANGE_INVERTED",
        "animation range " .. #ranges .. " of descriptor " .. descriptorIndex .. " ends before it starts",
        { descriptor = descriptorIndex, index = #ranges, startFrame = startFrame, endFrame = endFrame }
      )
    end
    ranges[#ranges + 1] = {
      startFrame = startFrame,
      endFrame = endFrame,
      endMode = endMode,
      loop = endMode == 0,
    }
    offset = offset + RANGE_SIZE
    if #ranges > MAX_RANGES then
      raise(
        "FIELD_ACTOR_RANGES_TOO_LARGE",
        "descriptor " .. descriptorIndex .. " declares more than " .. MAX_RANGES .. " ranges",
        { descriptor = descriptorIndex, limit = MAX_RANGES }
      )
    end
  end
  if #ranges == 0 then
    raise(
      "FIELD_ACTOR_RANGES_EMPTY",
      "descriptor " .. descriptorIndex .. " has no animation ranges",
      { descriptor = descriptorIndex }
    )
  end
  return ranges
end

local function decodeDescriptors(reader, locator, tables)
  local base = offsetFor(locator, tables.descriptors.address, "descriptor table")
  local descriptors = {}
  for index = 0, tables.descriptors.count - 1 do
    local offset = base + index * DESCRIPTOR_SIZE
    if offset + DESCRIPTOR_SIZE > locator.size then
      raise(
        "FIELD_ACTOR_DESCRIPTOR_OUT_OF_OVERLAY",
        "descriptor " .. index .. " reaches past the end of the overlay",
        { descriptor = index, offset = offset }
      )
    end
    local rangesAddress = reader:u32le(offset + 4)
    descriptors[index] = {
      index = index,
      reserved = { reader:u8(offset), reader:u8(offset + 1) },
      modelKey = reader:u8(offset + 2),
      timelineKey = reader:u8(offset + 3),
      rangesAddress = rangesAddress,
      ranges = decodeRanges(reader, locator, rangesAddress, index),
    }
  end
  return descriptors
end

local function decodeStaticModels(reader, locator, config)
  if not config then
    return nil
  end
  local offset = offsetFor(locator, config.table.address, "static model table")
  local bySpriteId, order = {}, {}
  for _ = 1, config.table.count do
    local spriteId = reader:u32le(offset)
    local memberId = reader:u32le(offset + 4)
    assert(not bySpriteId[spriteId], "duplicate static model spriteId " .. spriteId)
    bySpriteId[spriteId] = memberId
    order[#order + 1] = spriteId
    offset = offset + 8
  end
  return { descriptor = config.descriptor, bySpriteId = bySpriteId, order = order }
end

local function _decode(overlayBytes, locator, manifest)
  assert(type(overlayBytes) == "string", "overlay bytes must be a string")
  assert(type(locator) == "table" and locator.ramAddress, "locator requires a ramAddress")
  local tables = manifest.tables
  local bounded = {
    ramAddress = locator.ramAddress,
    size = #overlayBytes,
  }
  local reader = BinaryReader.new(overlayBytes, "field-actor-overlay")

  local graphics = decodeRecords(reader, bounded, tables)
  local result = {
    ramAddress = bounded.ramAddress,
    overlaySize = bounded.size,
    records = graphics.records,
    bySpriteId = graphics.bySpriteId,
    recordCount = #graphics.records,
    tableOffset = graphics.tableOffset,
    terminatorOffset = graphics.terminatorOffset,
    spanBytes = graphics.spanBytes,
    descriptors = decodeDescriptors(reader, bounded, tables),
    modelMembers = decodeKeyTable(reader, bounded, tables.modelKeys.address, "model key table"),
    timelineMembers = decodeKeyTable(reader, bounded, tables.timelineKeys.address, "timeline key table"),
    staticModels = decodeStaticModels(reader, bounded, manifest.staticModels),
  }

  -- Every descriptor must resolve through both key tables, or the bundle a
  -- sprite needs cannot be named at all.
  for index = 0, tables.descriptors.count - 1 do
    local descriptor = result.descriptors[index]
    descriptor.modelMemberId = result.modelMembers.byKey[descriptor.modelKey]
    descriptor.timelineMemberId = result.timelineMembers.byKey[descriptor.timelineKey]
    if not descriptor.modelMemberId then
      raise(
        "FIELD_ACTOR_MODEL_KEY_UNKNOWN",
        "descriptor " .. index .. " uses unmapped model key " .. descriptor.modelKey,
        { descriptor = index, modelKey = descriptor.modelKey }
      )
    end
    if not descriptor.timelineMemberId then
      raise(
        "FIELD_ACTOR_TIMELINE_KEY_UNKNOWN",
        "descriptor " .. index .. " uses unmapped timeline key " .. descriptor.timelineKey,
        { descriptor = index, timelineKey = descriptor.timelineKey }
      )
    end
  end

  return result
end

-- overlayBytes: the decompressed overlay 1 image.
-- locator: { ramAddress = <load address reported by the ROM overlay table> }.
-- manifest: data/manifests/field_actors.lua (or a fixture with the same shape).
function FieldActorGraphics.decode(overlayBytes, locator, manifest)
  local ok, result = pcall(_decode, overlayBytes, locator, manifest)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

-- Resolve one spriteId to its record and the descriptor it selects. Variable
-- sprite IDs are absent from the table by design and are reported as such.
function FieldActorGraphics.resolve(decoded, spriteId)
  local record = decoded.bySpriteId[spriteId]
  if not record then
    return nil,
      Errors.new(
        "FIELD_ACTOR_SPRITE_ABSENT",
        "spriteId " .. tostring(spriteId) .. " is not in the graphics table",
        { spriteId = spriteId }
      )
  end
  local descriptor = decoded.descriptors[record.visualDescriptor]
  if not descriptor then
    local staticModels = decoded.staticModels
    if staticModels and record.visualDescriptor == staticModels.descriptor then
      local memberId = staticModels.bySpriteId[spriteId]
      if not memberId then
        return nil,
          Errors.new(
            "FIELD_ACTOR_STATIC_MODEL_UNKNOWN",
            "spriteId " .. spriteId .. " has no static model member mapping",
            { spriteId = spriteId, descriptor = record.visualDescriptor }
          )
      end
      return { record = record, staticModelMemberId = memberId }
    end
    return nil,
      Errors.new(
        "FIELD_ACTOR_DESCRIPTOR_UNKNOWN",
        "spriteId "
          .. spriteId
          .. " selects descriptor "
          .. record.visualDescriptor
          .. ", which the table does not define",
        { spriteId = spriteId, descriptor = record.visualDescriptor }
      )
  end
  return { record = record, descriptor = descriptor }
end

return FieldActorGraphics
