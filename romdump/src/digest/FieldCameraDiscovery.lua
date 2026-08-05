-- Discovers the HGSS field-camera table through the duplicate RAM pointers in
-- ARM9 overlay 1. This keeps version-specific offsets out of the binary parser.

local BinaryReader = require("libs.rom.src.BinaryReader")
local Errors = require("libs.rom.src.Errors")

local FieldCameraDiscovery = {}

local function _discover(overlayBytes, overlayInfo, config)
  assert(type(overlayBytes) == "string", "overlay bytes are required")
  assert(type(overlayInfo) == "table", "overlay info is required")
  assert(type(config) == "table", "discovery config is required")
  assert(#config.pointerFileOffsets > 0, "pointerFileOffsets must not be empty")
  assert(config.recordSize == 0x24, "HGSS camera record size must be 0x24")
  local reader = BinaryReader.new(overlayBytes, overlayInfo.path or "camera-overlay")
  local tableRamAddress
  for _, offset in ipairs(config.pointerFileOffsets) do
    if offset < 0 or offset + 4 > #overlayBytes then
      Errors.raise("FIELD_CAMERA_POINTER_OUT_OF_BOUNDS",
        "camera pointer is outside its overlay",
        { pointerFileOffset = offset, overlayByteLength = #overlayBytes })
    end
    local pointer = reader:u32le(offset)
    if tableRamAddress and pointer ~= tableRamAddress then
      Errors.raise("FIELD_CAMERA_POINTER_MISMATCH",
        string.format("camera pointers disagree: 0x%08X ~= 0x%08X", pointer, tableRamAddress),
        { pointerFileOffset = offset, actual = pointer, expected = tableRamAddress })
    end
    tableRamAddress = pointer
  end
  if config.expectedTableRamAddress
      and tableRamAddress ~= config.expectedTableRamAddress then
    Errors.raise("FIELD_CAMERA_TABLE_ADDRESS_UNEXPECTED",
      string.format("camera table address 0x%08X ~= expected 0x%08X",
        tableRamAddress, config.expectedTableRamAddress),
      { actual = tableRamAddress, expected = config.expectedTableRamAddress })
  end
  local tableFileOffset = tableRamAddress - overlayInfo.ramAddress
  local tableByteLength = config.recordCount * config.recordSize
  if tableFileOffset < 0 or tableFileOffset + tableByteLength > #overlayBytes then
    Errors.raise("FIELD_CAMERA_TABLE_OUT_OF_BOUNDS", "discovered camera table is outside its overlay",
      { tableFileOffset = tableFileOffset, tableByteLength = tableByteLength,
        overlayByteLength = #overlayBytes })
  end
  return {
    tableRamAddress = tableRamAddress,
    tableFileOffset = tableFileOffset,
    tableByteLength = tableByteLength,
  }
end

function FieldCameraDiscovery.discover(overlayBytes, overlayInfo, config)
  local ok, result = pcall(_discover, overlayBytes, overlayInfo, config)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return FieldCameraDiscovery
