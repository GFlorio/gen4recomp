-- Resolves the source frame pairs a field-actor resource can actually display.
-- Ordinary resources follow their decoded timeline. A resource with exactly one
-- texture and palette is intrinsically static, even when its shared descriptor
-- carries directional slots that do not exist in that resource (HGSS rocks use
-- this shape). Pure domain module; no love dependency.

local Errors = require("libs.rom.src.Errors")
local FieldActorTimeline = require("romdump.src.digest.FieldActorTimeline")

local FieldActorFrames = {}

local function timelineFrames(timeline, ranges)
  local frames, byKey, perRange = {}, {}, {}
  for index, range in ipairs(ranges) do
    local displayed = FieldActorTimeline.framesForRange(timeline, range)
    local mapped = {}
    for _, frame in ipairs(displayed) do
      local key = frame.textureSlot .. ":" .. frame.paletteSlot
      local frameIndex = byKey[key]
      if not frameIndex then
        frames[#frames + 1] = {
          textureSlot = frame.textureSlot,
          paletteSlot = frame.paletteSlot,
        }
        frameIndex = #frames
        byKey[key] = frameIndex
      end
      mapped[#mapped + 1] = { frameIndex = frameIndex, ticks = frame.ticks }
    end
    perRange[index] = mapped
  end
  return frames, perRange
end

local function missingSlot(frames, textureCount, paletteCount)
  for _, frame in ipairs(frames) do
    if frame.textureSlot >= textureCount then
      return "texture", frame.textureSlot
    end
    if frame.paletteSlot >= paletteCount then
      return "palette", frame.paletteSlot
    end
  end
end

local function staticResult(ranges)
  local perRange = {}
  for index, range in ipairs(ranges) do
    perRange[index] = {
      { frameIndex = 1, ticks = range.endFrame - range.startFrame + 1 },
    }
  end
  return {
    mode = "static",
    frames = { { textureSlot = 0, paletteSlot = 0 } },
    perRange = perRange,
  }
end

function FieldActorFrames.collect(timeline, ranges, textureCount, paletteCount, context)
  assert(type(textureCount) == "number" and textureCount > 0, "field actor needs at least one texture")
  assert(type(paletteCount) == "number" and paletteCount > 0, "field actor needs at least one palette")

  local frames, perRange = timelineFrames(timeline, ranges)
  local kind, slot = missingSlot(frames, textureCount, paletteCount)
  if not kind then
    return { mode = "timeline", frames = frames, perRange = perRange }
  end
  if textureCount == 1 and paletteCount == 1 then
    return staticResult(ranges)
  end
  if kind == "texture" then
    Errors.raise(
      "FIELD_ACTOR_TEXTURE_SLOT_MISSING",
      "timeline references texture slot " .. slot .. " but the actor resource has " .. textureCount,
      { textureSlot = slot, count = textureCount, context = context }
    )
  end
  Errors.raise(
    "FIELD_ACTOR_PALETTE_SLOT_MISSING",
    "timeline references palette slot " .. slot .. " but the actor resource has " .. paletteCount,
    { paletteSlot = slot, count = paletteCount, context = context }
  )
end

return FieldActorFrames
