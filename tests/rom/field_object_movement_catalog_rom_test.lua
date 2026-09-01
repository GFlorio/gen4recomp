-- ROM census for source object movement selectors and generated semantic records.

local Assert = require("tests.support.Assert")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local FieldObjectMovement = require("libs.assets.src.FieldObjectMovement")
local ZoneEvents = require("romdump.src.digest.ZoneEvents")

local T = {}

function T.object_events_and_generated_records_use_catalog_movement_types(romFs)
  local bundles = assert(FieldMapDataCompiler.compileAll(romFs))
  local archive = assert(romFs:openNarc("zone_events"))
  for _, bundle in ipairs(bundles) do
    local mapId = bundle.mapId
    local record = assert(bundle.field)
    for _, object in ipairs(record.events.objects) do
      Assert.isTrue(type(object.movementType) == "string", "map " .. mapId .. " object is semantic")
      Assert.isTrue(FieldObjectMovement.isType(object.movementType), "map " .. mapId .. " object type")
      Assert.isNil(object.movement, "map " .. mapId .. " object has no raw movement")
    end
    local raw = assert(ZoneEvents.decode(archive:readMember(assert(bundle.dependencies.eventMemberId)), {
      mapId = mapId,
      eventMemberId = bundle.dependencies.eventMemberId,
      source = "fielddata_eventdata_zone_event",
    }))
    Assert.equal(#raw.objectEvents, #record.events.objects, "map " .. mapId .. " object count")
    for index, object in ipairs(raw.objectEvents) do
      Assert.isTrue(object.movement >= 0 and object.movement <= 56, "map " .. mapId .. " source movement")
      Assert.equal(
        record.events.objects[index].movementType,
        require("romdump.src.digest.HgssObjectMovement").semanticType(object.movement)
      )
      Assert.equal(record.events.objects[index].xRange, object.xRange, "map " .. mapId .. " source/generated x range")
      Assert.equal(record.events.objects[index].yRange, object.yRange, "map " .. mapId .. " source/generated y range")
    end
  end
end

return require("tests.rom.support.RomSuite").fromFacts(T)
