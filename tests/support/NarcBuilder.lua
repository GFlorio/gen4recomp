-- Test helper: assemble NARC archives in memory, valid or deliberately
-- malformed. A NARC is a 16-byte header followed by blockCount
-- blocks (BTAF member table, BTNF names, GMIF data). Member offsets in BTAF are
-- relative to the GMIF payload and 4-byte aligned, matching pret's o2narc.
--
-- NarcBuilder.build(members, opts) where members is a zero-or-more array of
-- binary member strings and opts selects one corruption:
--   { declaredSizeTooLarge=, missingBtaf=, missingGmif=, duplicateBtaf=,
--     memberOutOfRange=, tinyBlock= }

local FntWriter = require("tests.support.FntWriter")

local NarcBuilder = {}

local u16, u32 = FntWriter.u16, FntWriter.u32
local HEADER_SIZE = 0x10

-- 4-byte-aligned member layout within the GMIF payload.
local function layout(members)
  local fat, parts, pos = {}, {}, 0
  for i, m in ipairs(members) do
    local start = pos
    fat[i] = { start = start, endOffset = start + #m }
    parts[#parts + 1] = m
    pos = start + #m
    local pad = (4 - pos % 4) % 4
    if pad > 0 and i < #members then
      parts[#parts + 1] = string.rep("\0", pad)
      pos = pos + pad
    end
  end
  return fat, table.concat(parts)
end

local function block(magic, payload)
  return magic .. u32(8 + #payload) .. payload
end

function NarcBuilder.build(members, opts)
  members = members or {}
  opts = opts or {}

  local fat, gmifPayload = layout(members)
  if opts.memberOutOfRange and fat[1] then
    fat[1].endOffset = #gmifPayload + 16 -- reaches past the GMIF payload
  end

  local btafParts = { u16(#members), u16(0) }
  for _, e in ipairs(fat) do
    btafParts[#btafParts + 1] = u32(e.start) .. u32(e.endOffset)
  end

  -- Minimal single-entry BTNF, as o2narc emits; HGSS members are unnamed.
  local btnf = block("BTNF", u32(4) .. u16(0) .. u16(1))
  local btaf = block("BTAF", table.concat(btafParts))
  local gmif = block("GMIF", gmifPayload)
  if opts.tinyBlock then
    btaf = "BTAF" .. u32(4) -- declared size below the 8-byte minimum
  end

  local blocks = {}
  if not opts.missingBtaf then
    blocks[#blocks + 1] = btaf
  end
  if opts.duplicateBtaf then
    blocks[#blocks + 1] = btaf
  end
  blocks[#blocks + 1] = btnf
  if not opts.missingGmif then
    blocks[#blocks + 1] = gmif
  end
  local body = table.concat(blocks)

  local fileSize = HEADER_SIZE + #body
  if opts.declaredSizeTooLarge then
    fileSize = fileSize + 64
  end

  local header = "NARC" .. u16(0xFFFE) .. u16(0x0100) .. u32(fileSize) .. u16(HEADER_SIZE) .. u16(#blocks)
  return header .. body
end

return NarcBuilder
