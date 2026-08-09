-- Assembles synthetic HGSS land-data members for tests: the 4-word size header,
-- the BGS block, then permissions / buildings / embedded-model / BDHC sections.
-- Every field is overridable so tests can produce both valid members and
-- malformed copies that exercise each structured failure code. Test-only.

local LandDataBuilder = {}

local function u16(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- opts (all optional):
--   bgsSignature  default 0x1234
--   bgsPayload    default "" (ordinary map chunks carry no BGS payload)
--   permissions   default 0x800 zero bytes
--   buildings     default "" (a concatenation of 0x30-byte records)
--   model         default a minimal 0x10-byte "BMD0" section
--   bdhc          default "" (when non-empty it should start with "BDHC")
function LandDataBuilder.build(opts)
  opts = opts or {}
  local bgsPayload = opts.bgsPayload or ""
  local permissions = opts.permissions or string.rep("\0", 0x800)
  local buildings = opts.buildings or ""
  local model = opts.model or ("BMD0" .. string.rep("\0", 0x0C))
  local bdhc = opts.bdhc or ""

  local sizeHeader = u32(#permissions) .. u32(#buildings) .. u32(#model) .. u32(#bdhc)
  local bgs = u16(opts.bgsSignature or 0x1234) .. u16(#bgsPayload) .. bgsPayload
  return sizeHeader .. bgs .. permissions .. buildings .. model .. bdhc
end

-- A minimal valid 0x30-byte placed-building record referencing modelMemberId,
-- at the origin, unrotated, at unit scale (fx32 0x1000 == 1.0).
function LandDataBuilder.buildingRecord(modelMemberId)
  return u32(modelMemberId or 0)
    .. string.rep("\0", 0x1C - 4)
    .. u32(0x1000)
    .. u32(0x1000)
    .. u32(0x1000)
    .. string.rep("\0", 8)
end

return LandDataBuilder
