-- ROM-conformance test for the object-actor lifecycle against real ROM data:
-- actors resolve their source events and terrain surfaces, and repeated map
-- entry neither duplicates an identity nor leaks a visual reference.
--
-- Visual loading is stubbed here on purpose: the compiled bundle is the subject
-- of field_actors_test. This test is about lifecycle over real
-- event, flag, and terrain data.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local HgssBdhc = require("romdump.src.digest.HgssBdhc")
local LandData = require("romdump.src.digest.LandData")
local MapResolver = require("romdump.src.digest.MapResolver")
local TerrainSurface = require("libs.engine.src.TerrainSurface")
local actorManifest = require("romdump.src.config.FieldActors")

local T = {}

local LAB = 61

local POLICY = {
  variableSprites = {
    first = actorManifest.variableSpriteRange.first,
    last = actorManifest.variableSpriteRange.last,
    variableBase = actorManifest.variableVarBase,
  },
}

local function stubAssets()
  return {
    references = {},
    knows = function()
      return true
    end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = { spriteId = spriteId } }
    end,
    release = function(self, spriteId)
      self.references[spriteId] = assert(self.references[spriteId]) - 1
    end,
    total = function(self)
      local sum = 0
      for _, count in pairs(self.references) do
        sum = sum + count
      end
      return sum
    end,
  }
end

local function fieldDataFor(romFs)
  local cache = {}
  return function(mapId)
    if not cache[mapId] then
      cache[mapId] = assert(FieldMapDataCompiler.compile(romFs, mapId)).field
    end
    return cache[mapId]
  end
end

-- The laboratory is a single matrix cell with a single flat BDHC plate, so its
-- central terrain is the whole runtime terrain and no neighbour ring is needed.
local function labRuntimeMap(romFs, fieldData)
  local resolved = assert(MapResolver.resolve(romFs, LAB))
  local bytes = assert(romFs:openNarc("land_data")):readMember(resolved.landDataMemberId)
  local land =
    assert(LandData.decode(bytes, { mapId = LAB, alias = "land_data", memberId = resolved.landDataMemberId }))
  local bdhc =
    assert(HgssBdhc.decode(land.bdhcBytes, { mapId = LAB, alias = "land_data", memberId = resolved.landDataMemberId }))
  return {
    mapId = LAB,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
    },
    terrain = TerrainSurface.new({ plates = bdhc.plates }),
    fieldData = fieldData,
  }
end

local function labSession(romFs)
  local reader = fieldDataFor(romFs)
  local eventState = FieldEventState.new()
  local assets = stubAssets()
  local manager = FieldActorManager.new({ assets = assets, policy = POLICY })
  ---@cast manager FieldActorManager
  local map = labRuntimeMap(romFs, reader(LAB))
  ---@cast map RuntimeFieldMap
  manager:enterMap(map, eventState)
  return manager, eventState, assets, map
end

function T.every_target_map_object_event_id_is_unique(romFs)
  local reader = fieldDataFor(romFs)
  for _, mapId in ipairs({ 60, LAB }) do
    local seen = {}
    for _, event in ipairs(reader(mapId).events.objects) do
      Assert.isNil(seen[event.objectEventId], "map " .. mapId .. " repeats object event " .. event.objectEventId)
      seen[event.objectEventId] = true
    end
  end
end

function T.visible_lab_actors_resolve_one_surface_and_occupy_their_cell(romFs)
  local manager = labSession(romFs)
  ---@cast manager FieldActorManager
  for _, actor in ipairs(FieldActorManager.actorsOf(manager, LAB)) do
    Assert.equal(actor.surfaceId, 0)
    Assert.equal(actor.worldY, 0)
    local occupied = manager:isOccupied(LAB, {
      fieldX = actor.fieldX,
      fieldZ = actor.fieldZ,
      surfaceId = actor.surfaceId,
      cellKey = actor.cellKey,
      sourceSurfaceId = actor.sourceSurfaceId,
    })
    Assert.equal(occupied, actor.solid)
  end
  local elm = assert(manager:getById("map:61:object:0"))
  Assert.equal(elm.spriteId, 99)
  Assert.equal(elm.facing, "south")
  Assert.equal(elm.sourceEvent.eventFlag, 401)
  Assert.equal(elm.sourceEvent.scriptId, 1)

  local friend = assert(manager:getById("map:61:object:3"))
  Assert.equal(friend.fieldX, 4)
  Assert.equal(friend.fieldZ, 14)
  Assert.isTrue(friend.solid)
  Assert.isTrue(manager:isOccupied(LAB, {
    fieldX = friend.fieldX,
    fieldZ = friend.fieldZ,
    surfaceId = friend.surfaceId,
    cellKey = friend.cellKey,
    sourceSurfaceId = friend.sourceSurfaceId,
  }))
end

function T.flag_toggles_remove_and_restore_elm_on_one_step(romFs)
  local manager, eventState = labSession(romFs)
  local elm = assert(manager:getById("map:61:object:0"))
  eventState:setFlag(elm.sourceEvent.eventFlag)
  manager:step(1)
  Assert.isNil(manager:getById("map:61:object:0"))
  Assert.isFalse(manager:isOccupied(LAB, {
    fieldX = elm.fieldX,
    fieldZ = elm.fieldZ,
    surfaceId = elm.surfaceId,
    cellKey = elm.cellKey,
    sourceSurfaceId = elm.sourceSurfaceId,
  }))
  eventState:clearFlag(elm.sourceEvent.eventFlag)
  manager:step(2)
  Assert.notNil(manager:getById("map:61:object:0"))
  Assert.isTrue(manager:isOccupied(LAB, {
    fieldX = elm.fieldX,
    fieldZ = elm.fieldZ,
    surfaceId = elm.surfaceId,
    cellKey = elm.cellKey,
    sourceSurfaceId = elm.sourceSurfaceId,
  }))
end

function T.repeated_lab_entry_keeps_identities_stable_and_visuals_balanced(romFs)
  local manager, eventState, assets, map = labSession(romFs)
  local baseline = assets:total()
  for _ = 1, 4 do
    manager:leaveMap(LAB)
    Assert.equal(assets:total(), 0)
    manager:enterMap(map, eventState)
    Assert.equal(assets:total(), baseline)
    Assert.equal(#FieldActorManager.actorsOf(manager, LAB), baseline)
  end
  manager:dispose()
  Assert.equal(assets:total(), 0)
end

return require("tests.rom.support.RomSuite").fromFacts(T)
