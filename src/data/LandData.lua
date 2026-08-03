-- Decoder for an HGSS land-data member: the container holding a map chunk's
-- collision permissions, placed-building records, embedded map NSBMD, and BDHC
-- envelope. The outer layout is a 0x10-byte header of four section sizes, then
-- a BGS block (signature 0x1234 + payload), then the four sections in order.
-- Layout from the recovered HGSS field engine; ordinary map chunks carry an
-- empty BGS payload, placing permissions at 0x14. Pure domain module;
-- decode() returns (land | nil, err). BDHC bytes are preserved opaquely.

local Errors = require("src.import.Errors")
local BinaryReader = require("src.import.BinaryReader")
local PermissionGrid = require("src.data.PermissionGrid")
local BuildingPlacement = require("src.data.BuildingPlacement")

local LandData = {}

local HEADER_SIZE = 0x10
local BGS_OFFSET = 0x10
local BGS_HEADER_SIZE = 4
local MIN_SIZE = BGS_OFFSET + BGS_HEADER_SIZE -- must reach the BGS payload length
local BGS_SIGNATURE = 0x1234
local PERMISSIONS_SIZE = 0x800
local BUILDING_RECORD_SIZE = 0x30
local MIN_MODEL_SIZE = 0x10

local function fail(code, message, context, extra)
  extra = extra or {}
  extra.source = context
  Errors.raise(code, message, extra)
end

local function parse(bytes, context)
  if #bytes < MIN_SIZE then
    fail("LAND_DATA_TOO_SMALL",
      "land-data member is " .. #bytes .. " bytes, need at least " .. MIN_SIZE,
      context, { size = #bytes, expected = MIN_SIZE })
  end
  local r = BinaryReader.new(bytes, "land-data")

  local permissionsSize = r:u32le(0x00)
  local buildingsSize = r:u32le(0x04)
  local modelSize = r:u32le(0x08)
  local bdhcSize = r:u32le(0x0C)

  local signature = r:u16le(BGS_OFFSET)
  if signature ~= BGS_SIGNATURE then
    fail("LAND_DATA_BAD_BGS_MAGIC",
      string.format("BGS signature 0x%04X != 0x%04X", signature, BGS_SIGNATURE),
      context, { offset = BGS_OFFSET, expected = BGS_SIGNATURE, actual = signature })
  end
  local bgsPayloadSize = r:u16le(BGS_OFFSET + 2)

  local permissionsOffset = BGS_OFFSET + BGS_HEADER_SIZE + bgsPayloadSize
  local buildingsOffset = permissionsOffset + permissionsSize
  local modelOffset = buildingsOffset + buildingsSize
  local bdhcOffset = modelOffset + modelSize
  local expectedEnd = bdhcOffset + bdhcSize

  if expectedEnd ~= #bytes then
    fail("LAND_DATA_BAD_SECTION_SUM",
      "section sizes sum to " .. expectedEnd .. " but member is " .. #bytes .. " bytes",
      context, { offset = 0x00, expected = #bytes, actual = expectedEnd })
  end
  if permissionsSize ~= PERMISSIONS_SIZE then
    fail("LAND_DATA_BAD_PERMISSION_SIZE",
      "permissions section is " .. permissionsSize .. " bytes, expected " .. PERMISSIONS_SIZE,
      context, { offset = 0x00, expected = PERMISSIONS_SIZE, actual = permissionsSize })
  end
  if buildingsSize % BUILDING_RECORD_SIZE ~= 0 then
    fail("LAND_DATA_BAD_BUILDING_SIZE",
      "buildings section " .. buildingsSize .. " is not a multiple of " .. BUILDING_RECORD_SIZE,
      context, { offset = 0x04, actual = buildingsSize })
  end
  if modelSize < MIN_MODEL_SIZE or r:bytes(modelOffset, 4) ~= "BMD0" then
    fail("LAND_DATA_BAD_MODEL_MAGIC",
      "embedded model does not begin with BMD0",
      context, { offset = modelOffset, expected = "BMD0", actual = r:bytes(modelOffset, math.min(4, modelSize)) })
  end
  if bdhcSize > 0 and r:bytes(bdhcOffset, 4) ~= "BDHC" then
    fail("LAND_DATA_BAD_BDHC_MAGIC",
      "BDHC section does not begin with BDHC",
      context, { offset = bdhcOffset, expected = "BDHC", actual = r:bytes(bdhcOffset, 4) })
  end

  local permissions, permErr = PermissionGrid.decode(r:bytes(permissionsOffset, permissionsSize), context)
  if not permissions then error(permErr) end
  local buildings, buildErr = BuildingPlacement.decodeAll(r:bytes(buildingsOffset, buildingsSize), context)
  if not buildings then error(buildErr) end

  return {
    bgs = {
      signature = signature,
      payload = r:bytes(BGS_OFFSET + BGS_HEADER_SIZE, bgsPayloadSize),
    },
    permissions = permissions,
    buildings = buildings,
    mapModelBytes = r:bytes(modelOffset, modelSize),
    bdhcBytes = r:bytes(bdhcOffset, bdhcSize),
    offsets = {
      permissions = permissionsOffset,
      buildings = buildingsOffset,
      model = modelOffset,
      bdhc = bdhcOffset,
    },
    sizes = {
      permissions = permissionsSize,
      buildings = buildingsSize,
      model = modelSize,
      bdhc = bdhcSize,
    },
    source = context,
  }
end

function LandData.decode(bytes, context)
  assert(type(bytes) == "string", "LandData.decode requires a string")
  local ok, result = pcall(parse, bytes, context)
  if ok then return result end
  if Errors.is(result) then return nil, result end
  error(result)
end

return LandData
