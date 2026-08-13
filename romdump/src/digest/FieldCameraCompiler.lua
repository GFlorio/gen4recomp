-- Compiles ROM-derived HGSS camera records into deterministic normalized field
-- profiles. Overlay discovery, decoding, and provenance remain separate steps.

local Errors = require("libs.errors.src.Errors")
local HgssCameraTable = require("romdump.src.digest.HgssCameraTable")
local FieldCameraDiscovery = require("romdump.src.digest.FieldCameraDiscovery")
local Hashing = require("romdump.src.digest.Hashing")
local FieldCameraCache = require("libs.assets.src.FieldCameraCache")
local Manifest = require("romdump.src.config.FieldCameras")

local FieldCameraCompiler = {}

local function _compile(romFs, config, sha1hex)
  assert(romFs and romFs.readOverlay, "compile requires a RomFs-shaped object")
  config = config or Manifest[romFs:version()]
  if not config then
    Errors.raise(
      "FIELD_CAMERA_VERSION_UNSUPPORTED",
      "no field-camera discovery metadata for " .. tostring(romFs:version()),
      { version = romFs:version() }
    )
  end
  local overlayBytes, overlayInfo = romFs:readOverlay(config.cpu, config.overlayId)
  if not overlayBytes then
    error(overlayInfo)
  end
  local found, discoveryErr = FieldCameraDiscovery.discover(overlayBytes, overlayInfo, config)
  if not found then
    error(discoveryErr)
  end
  local decoded, decodeErr = HgssCameraTable.decode(overlayBytes, {
    tableOffset = found.tableFileOffset,
    recordCount = config.recordCount,
    source = config.cpu .. "-overlay-" .. config.overlayId,
  })
  if not decoded then
    error(decodeErr)
  end
  assert(decoded.recordCount == config.recordCount)
  local overlaySha1 = (sha1hex or Hashing.sha1hex)(overlayBytes)
  local provenance = {
    cpu = config.cpu,
    overlayId = config.overlayId,
    fileId = overlayInfo.fileId,
    path = overlayInfo.path,
    pointerFileOffsets = config.pointerFileOffsets,
    tableRamAddress = found.tableRamAddress,
    tableFileOffset = found.tableFileOffset,
    recordSize = config.recordSize,
    recordCount = config.recordCount,
    overlaySha1 = overlaySha1,
  }
  -- The runtime asset carries only normalized records; the raw HGSS field
  -- values stay with the decoder (HgssCameraTable) and the overlay provenance
  -- is written separately by the cache writer.
  local normalized = {}
  for cameraType = 0, decoded.recordCount - 1 do
    local record = decoded.records[cameraType]
    local clean = {}
    for key, value in pairs(record) do
      if key ~= "raw" then
        clean[key] = value
      end
    end
    normalized[cameraType] = clean
  end
  local profiles = {
    schema = FieldCameraCache.SCHEMA,
    recordCount = decoded.recordCount,
    profiles = normalized,
  }
  local marker = FieldCameraCache.FORMAT .. ":" .. romFs:metadata().sha1 .. ":" .. overlaySha1
  return { profiles = profiles, provenance = provenance, marker = marker }
end

function FieldCameraCompiler.compile(romFs, config, sha1hex)
  local ok, result = pcall(_compile, romFs, config, sha1hex)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result)
end

return FieldCameraCompiler
