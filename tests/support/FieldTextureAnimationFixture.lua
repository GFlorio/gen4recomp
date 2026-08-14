-- Smallest byte builder for a `field_texture_animations` member-0 table:
-- a little-endian u32 record count followed by fixed 52-byte records of a
-- NUL-padded 16-byte name and an 18-pair schedule, exactly as
-- `FieldTextureAnimation.parse` reads it. Live pairs are packed first; the
-- remaining pairs are the { 0xFF, 0xFF } terminator, so records always end
-- with a valid terminator. A record with no live pairs is malformed input
-- (the parser rejects an empty live schedule); `member({})` builds the
-- valid zero-record table. Test-only.

local NB = require("tests.support.NitroBuilder")

local FieldTextureAnimationFixture = {}

-- records: { { name = string, timeline = { { textureIndex, durationTicks },
-- ... } } } with live entries first (at most 18). Timeline entries are
-- { textureIndex, durationTicks } pairs in schedule order.
function FieldTextureAnimationFixture.member(records)
  local out = { NB.u32(#records) }
  for _, record in ipairs(records) do
    assert(#record.name <= 16, "a fixture record name fits the 16-byte field")
    assert(not record.timeline or #record.timeline <= 18, "a fixture record schedule fits the 18 pairs")
    out[#out + 1] = record.name .. string.rep("\0", 16 - #record.name)
    for pair = 1, 18 do
      local live = record.timeline and record.timeline[pair]
      if live then
        out[#out + 1] = NB.u8(live[1]) .. NB.u8(live[2])
      else
        out[#out + 1] = NB.u8(0xFF) .. NB.u8(0xFF)
      end
    end
  end
  return table.concat(out)
end

return FieldTextureAnimationFixture
