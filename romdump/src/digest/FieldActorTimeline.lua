-- Decoder for the field-actor timeline members of the `mmodel` archive. A
-- timeline maps animation time to the texture and palette slot the shared
-- billboard should display; the serialized layout is the one
-- `scripts/dump_mmodel_unk.py` writes in the pinned pret/pokeheartgold source:
--
--   u32 count
--   u16 threshold[count]
--   u8  textureSlot[count]
--   u8  paletteSlot[count]
--
-- `sub_02026DE0` selects the last entry whose threshold is less than or equal to
-- the integer animation frame and returns `textureSlot | (paletteSlot << 8)`, so
-- thresholds partition the frame axis and must be non-decreasing. Slot durations
-- are read from the thresholds rather than assumed uniform: Marill's
-- south-facing loop is deliberately uneven. Pure domain module.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")

local FieldActorTimeline = {}

FieldActorTimeline.DECODER_VERSION = "hgss-field-actor-timeline-v1"

local MAX_ENTRIES = 1024

local function _decode(bytes, context)
  assert(type(bytes) == "string", "timeline bytes must be a string")
  local reader = BinaryReader.new(bytes, "actor-timeline")
  if #bytes < 4 then
    Errors.raise("FIELD_ACTOR_TIMELINE_TRUNCATED",
      "timeline member is " .. #bytes .. " bytes, too short for its count",
      { size = #bytes, context = context })
  end
  local count = reader:u32le(0)
  if count == 0 or count > MAX_ENTRIES then
    Errors.raise("FIELD_ACTOR_TIMELINE_COUNT_INVALID",
      "timeline declares " .. count .. " entries, outside 1.." .. MAX_ENTRIES,
      { count = count, context = context })
  end
  local expected = 4 + count * 4
  if #bytes ~= expected then
    Errors.raise("FIELD_ACTOR_TIMELINE_SIZE_MISMATCH",
      "timeline with " .. count .. " entries should be " .. expected
        .. " bytes, member is " .. #bytes,
      { count = count, expected = expected, actual = #bytes, context = context })
  end

  local thresholds = 4
  local textures = thresholds + count * 2
  local palettes = textures + count
  local entries = {}
  local previous = -1
  for i = 0, count - 1 do
    local threshold = reader:u16le(thresholds + i * 2)
    if threshold < previous then
      Errors.raise("FIELD_ACTOR_TIMELINE_UNORDERED",
        "timeline threshold " .. i .. " (" .. threshold .. ") is below its predecessor",
        { index = i, threshold = threshold, previous = previous, context = context })
    end
    previous = threshold
    entries[i] = {
      threshold = threshold,
      textureSlot = reader:u8(textures + i),
      paletteSlot = reader:u8(palettes + i),
    }
  end
  if entries[0].threshold ~= 0 then
    Errors.raise("FIELD_ACTOR_TIMELINE_NO_ORIGIN",
      "timeline does not define a slot at frame 0 (first threshold is "
        .. entries[0].threshold .. ")",
      { threshold = entries[0].threshold, context = context })
  end

  return {
    decoderVersion = FieldActorTimeline.DECODER_VERSION,
    count = count,
    entries = entries, -- zero-based
  }
end

function FieldActorTimeline.decode(bytes, context)
  local ok, result = pcall(_decode, bytes, context)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

-- The slot pair displayed at an integer animation frame: the last entry whose
-- threshold does not exceed it.
function FieldActorTimeline.at(timeline, frame)
  local chosen = timeline.entries[0]
  for i = 0, timeline.count - 1 do
    local entry = timeline.entries[i]
    if entry.threshold > frame then break end
    chosen = entry
  end
  return chosen.textureSlot, chosen.paletteSlot
end

-- Walk one animation range tick by tick and collapse consecutive identical slot
-- pairs into displayed frames. Preserves the source's uneven durations, so a
-- four-entry uniform loop and Marill's 5/10/5 loop use the same representation.
function FieldActorTimeline.framesForRange(timeline, range)
  assert(range.endFrame >= range.startFrame, "inverted animation range")
  local frames = {}
  for frame = range.startFrame, range.endFrame do
    local textureSlot, paletteSlot = FieldActorTimeline.at(timeline, frame)
    local last = frames[#frames]
    if last and last.textureSlot == textureSlot and last.paletteSlot == paletteSlot then
      last.ticks = last.ticks + 1
    else
      frames[#frames + 1] = { textureSlot = textureSlot, paletteSlot = paletteSlot, ticks = 1 }
    end
  end
  return frames
end

return FieldActorTimeline
