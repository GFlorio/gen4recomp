-- ROM-conformance check for every canonical coordinate script binding in the
-- manifest. Expected identity comes from the frozen map catalog and decoded
-- zone-event records, not from the manifest target.

local Assert = require("tests.support.Assert")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local ZoneEvents = require("romdump.src.digest.ZoneEvents")
local RomSuite = require("tests.rom.support.RomSuite")
local manifest = require("data.scripts.manifests.vanilla_bindings")
local Identity = require("romdump.src.digest.script.VanillaBindingIdentity")

local function sortedMapIds()
  local mapIds = {}
  for mapId in pairs(manifest.maps) do
    mapIds[#mapIds + 1] = mapId
  end
  table.sort(mapIds)
  return mapIds
end

local function sortedCoordinateIndices(coordinates)
  local indices = {}
  for eventIndex in pairs(coordinates) do
    indices[#indices + 1] = eventIndex
  end
  table.sort(indices)
  return indices
end

local function validateManifest(romFs)
  local zoneEventsArchive = assert(romFs:openNarc("zone_events"))
  local declaredCoordinateCount = 0
  local inspectedCoordinateCount = 0
  local canonicalCount = 0

  for _, mapId in ipairs(sortedMapIds()) do
    local mapRecord = assert(MapCatalog.get(mapId))
    local mapBindings = assert(manifest.maps[mapId])
    local memberBytes = assert(zoneEventsArchive:readMember(mapRecord.eventMemberId))
    local events = assert(ZoneEvents.decode(memberBytes, {
      mapId = mapId,
      eventMemberId = mapRecord.eventMemberId,
      source = "coordinate binding identity",
    }))

    for _, eventIndex in ipairs(sortedCoordinateIndices(mapBindings.coordinates)) do
      declaredCoordinateCount = declaredCoordinateCount + 1
      local target = mapBindings.coordinates[eventIndex]
      local event = events.coordinateEvents[eventIndex + 1]
      Assert.notNil(
        event,
        string.format("map %d coordinate %d is absent from the decoded event member", mapId, eventIndex)
      )
      inspectedCoordinateCount = inspectedCoordinateCount + 1

      local identity = Identity.parseCanonicalTarget(target)
      if identity ~= nil then
        canonicalCount = canonicalCount + 1
        Assert.equal(
          identity.memberId,
          mapRecord.scriptsMemberId,
          string.format("map %d coordinate %d has the wrong script member", mapId, eventIndex)
        )
        local valid, err = Identity.validateCoordinateTarget(mapId, eventIndex, target, mapRecord, event)
        Assert.isTrue(valid, tostring(err))
        Assert.equal(
          identity.scriptIndex,
          event.scriptId - 1,
          string.format("map %d coordinate %d has the wrong public script index", mapId, eventIndex)
        )
      end
    end
  end

  Assert.equal(
    inspectedCoordinateCount,
    declaredCoordinateCount,
    "every manifest coordinate entry must be inspected against decoded source events"
  )
  Assert.isTrue(canonicalCount > 0, "the manifest must contain canonical coordinate targets to validate")
end

return RomSuite.fromFacts({
  every_coordinate_binding_matches_decoded_source_identity = validateManifest,
})
