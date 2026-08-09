-- ARM9/ARM7 overlay-table parser. Pure domain module: each 32-byte entry maps
-- an overlayId to the FAT fileId that holds its code, plus load metadata kept
-- for later reverse-engineering. Output is naming-agnostic: callers
-- name files by overlayId, never by table position.

local Errors = require("libs.rom.src.Errors")
local BinaryReader = require("libs.rom.src.BinaryReader")

local OverlayTable = {}

local ENTRY_SIZE = 32

function OverlayTable.parse(tableBytes, fatCount, label)
  assert(type(tableBytes) == "string", "overlay table bytes must be a string")
  assert(type(fatCount) == "number", "fatCount must be a number")
  if #tableBytes % ENTRY_SIZE ~= 0 then
    Errors.raise(
      "OVERLAY_TABLE_SIZE_INVALID",
      "overlay table size " .. #tableBytes .. " is not a multiple of " .. ENTRY_SIZE,
      { size = #tableBytes }
    )
  end

  local reader = BinaryReader.new(tableBytes, label or "overlay-table")
  local count = #tableBytes / ENTRY_SIZE
  local overlays = {}
  local seenOverlayId, seenFileId = {}, {}

  for i = 0, count - 1 do
    local base = i * ENTRY_SIZE
    local entry = {
      overlayId = reader:u32le(base),
      ramAddress = reader:u32le(base + 4),
      ramSize = reader:u32le(base + 8),
      bssSize = reader:u32le(base + 12),
      staticInitStart = reader:u32le(base + 16),
      staticInitEnd = reader:u32le(base + 20),
      fileId = reader:u32le(base + 24),
      flags = reader:u32le(base + 28),
    }
    if entry.fileId >= fatCount then
      Errors.raise(
        "OVERLAY_FILE_ID_OUT_OF_FAT",
        "overlay " .. entry.overlayId .. " references fileId " .. entry.fileId .. " outside FAT of " .. fatCount,
        { overlayId = entry.overlayId, fileId = entry.fileId, fatCount = fatCount }
      )
    end
    if seenOverlayId[entry.overlayId] then
      Errors.raise("OVERLAY_DUPLICATE_ID", "duplicate overlayId " .. entry.overlayId, { overlayId = entry.overlayId })
    end
    if seenFileId[entry.fileId] then
      Errors.raise(
        "OVERLAY_DUPLICATE_FILE_ID",
        "fileId " .. entry.fileId .. " assigned to more than one overlay",
        { fileId = entry.fileId, overlayId = entry.overlayId }
      )
    end
    seenOverlayId[entry.overlayId] = true
    seenFileId[entry.fileId] = true
    overlays[#overlays + 1] = entry
  end

  return overlays
end

return OverlayTable
