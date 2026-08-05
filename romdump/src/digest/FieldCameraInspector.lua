-- Read-only camera-profile summary for CLI or future diagnostic UI. It reports
-- exact raw and normalized fields without adding presentation/aspect policy.

local FieldCameraInspector = {}

function FieldCameraInspector.inspect(profiles)
  assert(type(profiles) == "table" and profiles.profiles, "profiles are required")
  local records = {}
  for cameraType = 0, profiles.recordCount - 1 do
    local p = assert(profiles.profiles[cameraType], "missing camera type " .. cameraType)
    records[#records + 1] = {
      cameraType = cameraType,
      projection = p.projection,
      distanceTiles = p.distanceTiles,
      elevationDegrees = p.elevationDegrees,
      yawDegrees = p.yawDegrees,
      halfFovDegrees = p.halfFovDegrees,
      nearTiles = p.nearTiles,
      farTiles = p.farTiles,
      raw = p.raw,
    }
  end
  return { provenance = profiles.source, records = records }
end

function FieldCameraInspector.lines(report)
  local source = report.provenance
  local lines = { string.format("field-camera\toverlay=%s:%d\ttable=0x%08X\tsha1=%s",
    source.cpu, source.overlayId, source.tableRamAddress, source.overlaySha1) }
  for _, profile in ipairs(report.records) do
    lines[#lines + 1] = string.format(
      "camera\ttype=%d\tprojection=%s\tdistance=%.6f\televation=%.6f\thalfFov=%.6f\tnear=%.6f\tfar=%.6f",
      profile.cameraType, profile.projection, profile.distanceTiles,
      profile.elevationDegrees, profile.halfFovDegrees, profile.nearTiles, profile.farTiles)
  end
  return lines
end

return FieldCameraInspector
