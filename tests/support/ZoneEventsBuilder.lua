-- Synthetic HGSS zone-event member builder. It mirrors all four count-prefixed
-- record layouts and is used to verify decoding without private ROM payloads.

local BinaryWriter = require("libs.codec.src.BinaryWriter")

local ZoneEventsBuilder = {}

local function unsigned(value, modulus)
  return value < 0 and value + modulus or value
end

local function background(writer, event)
  writer
    :u16(event.scriptId)
    :u16(event.type)
    :u32(unsigned(event.x, 0x100000000))
    :u32(unsigned(event.z, 0x100000000))
    :u32(unsigned(event.y, 0x100000000))
    :u32(event.direction)
end

local function object(writer, event)
  writer
    :u16(event.objectEventId)
    :u16(event.spriteId)
    :u16(event.movement)
    :u16(event.type)
    :u16(event.eventFlag)
    :u16(event.scriptId)
    :u16(unsigned(event.facingDirection, 0x10000))
    :u16(event.param0)
    :u16(event.param1)
    :u16(event.param2)
    :u16(unsigned(event.xRange, 0x10000))
    :u16(unsigned(event.yRange, 0x10000))
    :u16(event.x)
    :u16(event.z)
    :u32(unsigned(event.y, 0x100000000))
end

local function warp(writer, event)
  writer:u16(event.x):u16(event.z):u16(event.destinationMapId):u16(event.destinationWarpId):u32(event.y)
end

local function coordinate(writer, event)
  writer
    :u16(event.scriptId)
    :u16(unsigned(event.x, 0x10000))
    :u16(unsigned(event.z, 0x10000))
    :u16(event.width)
    :u16(event.height)
    :u16(event.y)
    :u16(event.requiredValue)
    :u16(event.variableId)
end

local function category(writer, records, encode)
  writer:u32(#records)
  for _, record in ipairs(records) do
    encode(writer, record)
  end
end

function ZoneEventsBuilder.build(events)
  events = events or {}
  local writer = BinaryWriter.new()
  category(writer, events.backgroundEvents or {}, background)
  category(writer, events.objectEvents or {}, object)
  category(writer, events.warps or {}, warp)
  category(writer, events.coordinateEvents or {}, coordinate)
  return writer:tostring()
end

return ZoneEventsBuilder
