-- Builds the raw BGS/soundplate bytes a HGSS land member embeds, for decoder
-- and field-map compiler tests. The engine's SoundplateStruct (field_control.c)
-- is the whole land BGS block: the 0x1234 signature bytes and a little-endian
-- u16 record byte count precede the 8-byte Soundplate records
-- (soundplateSoundID, volumeIndex, two unknown bytes, x, z, xBounds, zBounds).
-- `payload` builds the full struct/block shape the decoder consumes;
-- `records` builds the bare 8-byte record body the land BGS block wraps.
-- Every field is overridable so tests can produce both valid payloads and the
-- malformed copies that exercise each structured decoder failure. Test-only.

local SoundplateBuilder = {}

-- A single 8-byte Soundplate record.
---@param opts { soundId: integer, volumeIndex: integer, x: integer, z: integer, xBounds: integer, zBounds: integer, unknown2?: integer, unknown3?: integer }
---@return string
function SoundplateBuilder.record(opts)
  opts = opts or {}
  return string.char(
    opts.soundId % 256,
    opts.volumeIndex % 256,
    (opts.unknown2 or 0) % 256,
    (opts.unknown3 or 0) % 256,
    opts.x % 256,
    opts.z % 256,
    opts.xBounds % 256,
    opts.zBounds % 256
  )
end

-- The records-only body a land BGS block wraps: the 8-byte records with no
-- struct header, matching the real ROM's land BGS payload.
---@param opts { records?: table, trailing?: string }|nil
---@return string
function SoundplateBuilder.records(opts)
  opts = opts or {}
  local parts = {}
  for _, rec in ipairs(opts.records or {}) do
    parts[#parts + 1] = SoundplateBuilder.record(rec)
  end
  return table.concat(parts) .. (opts.trailing or "")
end

-- The complete SoundplateStruct/block payload: two unknown header bytes (the
-- 0x1234 signature in real data), a u16le record byte count, then the records.
-- `records` is an array of the record option tables; `recordBytes` overrides
-- the declared byte count independently of the concrete record bytes, and
-- `body`/`headerUnknown`/`trailing` allow building malformed copies directly.
---@param opts { records?: table, body?: string, recordBytes?: integer, headerUnknown?: string, trailing?: string }|nil
---@return string
function SoundplateBuilder.payload(opts)
  opts = opts or {}
  local body = opts.body
  if body == nil then
    local parts = {}
    for _, rec in ipairs(opts.records or {}) do
      parts[#parts + 1] = SoundplateBuilder.record(rec)
    end
    body = table.concat(parts)
  end
  local recordBytes = opts.recordBytes or #body
  local headerUnknown = opts.headerUnknown or "\0\0"
  return headerUnknown
    .. string.char(recordBytes % 256, math.floor(recordBytes / 256) % 256)
    .. body
    .. (opts.trailing or "")
end

return SoundplateBuilder
