-- Produces deterministic payload-light summaries of compiled field events for
-- the CLI. Records remain ordered by their zero-based source index. The source
-- member identity comes from the producer dependency record, which is the
-- only place source fields survive.

local FieldMapDataInspector = {}

function FieldMapDataInspector.inspect(field, dependencies)
  assert(type(field) == "table" and field.events, "field map data is required")
  assert(type(dependencies) == "table" and dependencies.eventMemberId ~= nil, "field dependencies are required")
  local e = field.events
  return {
    mapId = field.mapId,
    mapSymbol = field.mapSymbol,
    cameraType = field.cameraType,
    eventMemberId = dependencies.eventMemberId,
    counts = {
      background = #e.background,
      objects = #e.objects,
      warps = #e.warps,
      coordinates = #e.coordinates,
    },
    warps = e.warps,
  }
end

function FieldMapDataInspector.lines(report)
  local c = report.counts
  local lines = {
    string.format(
      "field-map\tmap=%d\tsymbol=%s\tcamera=%d\tmember=%d\tcounts=%d/%d/%d/%d",
      report.mapId,
      report.mapSymbol,
      report.cameraType,
      report.eventMemberId,
      c.background,
      c.objects,
      c.warps,
      c.coordinates
    ),
  }
  for _, warp in ipairs(report.warps) do
    lines[#lines + 1] = string.format(
      "warp\tmap=%d\tindex=%d\tx=%d\tz=%d\ty=%d\tdestination=%d:%d",
      report.mapId,
      warp.index,
      warp.x,
      warp.z,
      warp.y,
      warp.destinationMapId,
      warp.destinationWarpId
    )
  end
  return lines
end

return FieldMapDataInspector
