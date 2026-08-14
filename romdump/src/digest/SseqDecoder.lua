-- Strict SSEQ (sound sequence) event-stream decoder. The file layout follows
-- GBATEK's "DS Sound Files - SSEQ": a DATA block whose first byte is the
-- track count, per-track 32-bit offsets relative to the data area, then the
-- event stream per track (see the event table in the same GBATEK section,
-- which in turn cites loveemu's sseq2mid). Note gates and rests use a
-- variable-length field observed as additive 7-bit groups in the shipped
-- sequences (e.g. 0xC1 0x3C = 0x41 + 0x3C = 125 ticks). Any command the
-- renderer cannot honor raises instead of being dropped. Pure module.

local Errors = require("libs.errors.src.Errors")
local BinaryReader = require("libs.codec.src.BinaryReader")

local SseqDecoder = {}

local SUPPORTED_EVENTS = {
  [0x80] = "rest",
  [0x81] = "program",
  [0x93] = "track_pointer",
  [0x94] = "jump",
  [0x95] = "call",
  [0xC0] = "pan",
  [0xC1] = "volume",
  [0xC2] = "master_volume",
  [0xC3] = "transpose",
  [0xC4] = "pitch_bend",
  [0xC5] = "bend_range",
  [0xC6] = "priority",
  [0xC7] = "mono",
  [0xC8] = "tie",
  [0xC9] = "portamento_control",
  [0xCA] = "mod_depth",
  [0xCB] = "mod_speed",
  [0xCC] = "mod_type",
  [0xCD] = "mod_range",
  [0xCE] = "portamento",
  [0xCF] = "portamento_time",
  [0xD0] = "attack",
  [0xD1] = "decay",
  [0xD2] = "sustain",
  [0xD3] = "release",
  [0xD4] = "loop_start",
  [0xD5] = "expression",
  [0xD6] = "print_variable",
  [0xE0] = "mod_delay",
  [0xE1] = "tempo",
  [0xE3] = "sweep_pitch",
  [0xFC] = "loop_end",
  [0xFD] = "return",
  [0xFE] = "used_tracks",
  [0xFF] = "end",
}

-- The var-length field used by note gates, rests, and the program operand:
-- bytes with bit 7 set continue the field, and each byte contributes its low
-- 7 bits additively (observed encoding in the shipped UI sequences).
local function readVarLength(reader, pos)
  local value = 0
  local p = pos
  repeat
    local byte = reader:u8(p)
    value = value + byte % 128
    p = p + 1
    if p > reader:length() then
      Errors.raise("SSEQ_STREAM_INVALID", "var-length field runs past the sequence", { pos = pos })
    end
  until byte < 0x80
  return value, p
end

local function readTrack(reader, start, label)
  local events = {}
  local pos = start
  local guard = 0
  while guard < 100000 do
    guard = guard + 1
    if pos > reader:length() then
      Errors.raise("SSEQ_STREAM_INVALID", label .. " runs past the sequence", { pos = pos })
    end
    local opcode = reader:u8(pos)
    pos = pos + 1
    if opcode < 0x80 then
      local gate, after = readVarLength(reader, pos)
      events[#events + 1] = { kind = "note", velocity = opcode, gate = gate }
      pos = after
    else
      local kind = SUPPORTED_EVENTS[opcode]
      if not kind then
        Errors.raise("SSEQ_EVENT_UNSUPPORTED", label .. " uses unsupported event 0x" .. string.format("%02X", opcode), {
          opcode = opcode,
        })
      end
      if kind == "rest" then
        local ticks, after = readVarLength(reader, pos)
        events[#events + 1] = { kind = "rest", ticks = ticks }
        pos = after
      elseif kind == "program" then
        local value, after = readVarLength(reader, pos)
        events[#events + 1] = { kind = "program", program = value % 128, bank = math.floor(value / 128) }
        pos = after
      elseif kind == "track_pointer" or kind == "jump" or kind == "call" then
        if pos + 3 > reader:length() then
          Errors.raise("SSEQ_STREAM_INVALID", label .. " address event runs past the sequence", { pos = pos })
        end
        local target = reader:u8(pos) + reader:u8(pos + 1) * 256 + reader:u8(pos + 2) * 65536
        events[#events + 1] = { kind = kind, target = target }
        pos = pos + 3
      elseif kind == "mod_delay" or kind == "tempo" or kind == "sweep_pitch" then
        if pos + 1 > reader:length() then
          Errors.raise("SSEQ_STREAM_INVALID", label .. " word event runs past the sequence", { pos = pos })
        end
        local value = reader:u8(pos) + reader:u8(pos + 1) * 256
        events[#events + 1] = { kind = kind, value = value }
        pos = pos + 2
      elseif kind == "end" or kind == "loop_end" or kind == "return" or kind == "used_tracks" then
        if kind == "used_tracks" then
          -- 0xFE is a two-byte track bitmap; the 0x93 track pointers follow.
          local bitmap = reader:u8(pos)
          pos = pos + 1
          events[#events + 1] = { kind = kind, bitmap = bitmap }
        else
          events[#events + 1] = { kind = kind }
        end
        if kind == "end" then
          break
        end
      else
        local value = reader:u8(pos)
        pos = pos + 1
        events[#events + 1] = { kind = kind, value = value }
      end
    end
  end
  return events
end

local function _decode(data, label)
  local reader = BinaryReader.new(data, label or "sseq")
  if reader:length() < 0x1C or reader:ascii(0, 4) ~= "SSEQ" then
    Errors.raise("SSEQ_MAGIC_INVALID", "missing SSEQ header", { size = reader:length() })
  end
  local dataOffset = reader:u32le(0x18)
  if dataOffset + 1 > reader:length() then
    Errors.raise("SSEQ_STREAM_INVALID", "sequence data offset runs past the file", { dataOffset = dataOffset })
  end
  -- The shipped effect sequences are single tracks whose event stream starts
  -- directly at the data offset; multitrack files open with the 0xFE
  -- used-tracks bitmap followed by 0x93 track pointers.
  local tracks = {}
  local pos = dataOffset
  if reader:u8(dataOffset) == 0xFE then
    local bitmap = reader:u16le(dataOffset + 1)
    local pointerEnd = dataOffset + 3
    local pointers = {}
    while pointerEnd < reader:length() and reader:u8(pointerEnd) == 0x93 do
      local trackId = reader:u8(pointerEnd + 1)
      local target = reader:u8(pointerEnd + 2) + reader:u8(pointerEnd + 3) * 256 + reader:u8(pointerEnd + 4) * 65536
      pointers[trackId] = dataOffset + target
      pointerEnd = pointerEnd + 5
    end
    if next(pointers) == nil then
      Errors.raise("SSEQ_STREAM_INVALID", "multitrack SSEQ has no track pointers", {})
    end
    local count = 0
    for bit = 0, 15 do
      if math.floor(bitmap / 2 ^ bit) % 2 == 1 then
        count = count + 1
      end
    end
    -- Track 0 is the stream right after the pointer table; the pointers
    -- name the remaining used tracks.
    local ordered = {}
    for trackId = 1, 16 do
      if math.floor(bitmap / 2 ^ (trackId - 1)) % 2 == 1 then
        ordered[trackId] = pointers[trackId - 1] or pointerEnd
      end
    end
    local sequence = 1
    for trackId = 1, 16 do
      if ordered[trackId] then
        tracks[sequence] = { events = readTrack(reader, ordered[trackId], "track " .. (trackId - 1)) }
        sequence = sequence + 1
      end
    end
  else
    tracks[1] = { events = readTrack(reader, dataOffset, "track 0") }
  end
  return { tracks = tracks }
end

---@param data string
---@param opts? { label?: string }
---@return { tracks: { events: table[] }[] }?
---@return Errors.Error?
function SseqDecoder.decode(data, opts)
  assert(type(data) == "string", "SseqDecoder.decode requires a string")
  opts = opts or {}
  local ok, result = pcall(_decode, data, opts.label)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return SseqDecoder
