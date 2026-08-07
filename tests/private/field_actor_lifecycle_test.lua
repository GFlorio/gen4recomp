-- Private target gate for the object-actor lifecycle against real ROM data: the
-- deterministic scenario hides exactly the intended laboratory actors, every
-- visible target actor resolves one BDHC surface with no override, and repeated
-- map entry neither duplicates an identity nor leaks a visual reference.
--
-- Visual loading is stubbed here on purpose: the compiled bundle is the subject
-- of tests.private.field_actors_test. This test is about lifecycle over real
-- event, flag, and terrain data.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldMapDataCompiler = require("romdump.src.digest.FieldMapDataCompiler")
local FieldScenario = require("libs.engine.src.FieldScenario")
local HgssBdhc = require("libs.assets.src.HgssBdhc")
local LandData = require("romdump.src.digest.LandData")
local MapResolver = require("romdump.src.digest.MapResolver")
local TerrainSurface = require("libs.engine.src.TerrainSurface")
local actorManifest = require("data.manifests.field_actors")
local scenarioManifest = require("data.manifests.field_scenario")

local T = {}

local LAB = 61

local POLICY = {
  variableSpriteRange = actorManifest.variableSpriteRange,
  variableVarBase = actorManifest.variableVarBase,
}

local function stubAssets()
  return {
    references = {},
    knows = function() return true end,
    acquire = function(self, spriteId)
      self.references[spriteId] = (self.references[spriteId] or 0) + 1
      return { spriteId = spriteId, visual = { spriteId = spriteId } }
    end,
    release = function(self, spriteId)
      self.references[spriteId] = assert(self.references[spriteId]) - 1
    end,
    total = function(self)
      local sum = 0
      for _, count in pairs(self.references) do sum = sum + count end
      return sum
    end,
  }
end

local function fieldDataFor(romFs)
  local cache = {}
  return function(mapId)
    if not cache[mapId] then cache[mapId] = assert(FieldMapDataCompiler.compile(romFs, mapId)).field end
    return cache[mapId]
  end
end

-- The laboratory is a single matrix cell with a single flat BDHC plate, so its
-- central terrain is the whole runtime terrain and no neighbour ring is needed.
local function labRuntimeMap(romFs, fieldData)
  local resolved = assert(MapResolver.resolve(romFs, LAB))
  local bytes = assert(romFs:openNarc("land_data")):readMember(resolved.landDataMemberId)
  local land = assert(LandData.decode(bytes,
    { mapId = LAB, alias = "land_data", memberId = resolved.landDataMemberId }))
  local bdhc = assert(HgssBdhc.decode(land.bdhcBytes,
    { mapId = LAB, alias = "land_data", memberId = resolved.landDataMemberId }))
  return {
    mapId = LAB,
    coordinateOrigin = { x = 0, z = 0 },
    permissions = {
      containsLocal = function(_, x, z) return x >= 0 and x < 32 and z >= 0 and z < 32 end,
    },
    terrain = TerrainSurface.new({ plates = bdhc.plates }),
    fieldData = fieldData,
  }
end

local function labSession(romFs)
  local reader = fieldDataFor(romFs)
  local eventState = FieldEventState.new()
  FieldScenario.apply(scenarioManifest, eventState, reader)
  local assets = stubAssets()
  local manager = FieldActorManager.new({ assets = assets, policy = POLICY })
  local map = labRuntimeMap(romFs, reader(LAB))
  manager:enterMap(map, eventState)
  return manager, eventState, assets, map
end

function T.scenario_resolves_every_listed_object_to_a_rom_flag(romFs)
  local applied = FieldScenario.apply(scenarioManifest, FieldEventState.new(), fieldDataFor(romFs))
  Assert.equal(#applied, #scenarioManifest.visibility)
  for _, entry in ipairs(applied) do
    Assert.isTrue(entry.eventFlag > 0,
      "scenario entry " .. entry.mapId .. "/" .. entry.objectEventId .. " resolved to flag 0")
  end
end

function T.every_target_map_object_event_id_is_unique(romFs)
  local reader = fieldDataFor(romFs)
  for _, mapId in ipairs({ 60, LAB }) do
    local seen = {}
    for _, event in ipairs(reader(mapId).events.objects) do
      Assert.isNil(seen[event.objectEventId],
        "map " .. mapId .. " repeats object event " .. event.objectEventId)
      seen[event.objectEventId] = true
    end
  end
end

function T.demo_scenario_shows_elm_and_the_aide_and_hides_the_story_actors(romFs)
  local manager = labSession(romFs)
  Assert.notNil(manager:getById("map:61:object:0"), "Professor Elm must be visible")
  Assert.notNil(manager:getById("map:61:object:2"), "the aide must be visible")
  Assert.isNil(manager:getById("map:61:object:1"), "the officer must be hidden")
  Assert.isNil(manager:getById("map:61:object:3"), "the friend actor must be hidden")
  Assert.equal(#manager:actorsOf(LAB), 2)
end

function T.visible_lab_actors_resolve_one_surface_and_occupy_their_cell(romFs)
  local manager = labSession(romFs)
  for _, actor in ipairs(manager:actorsOf(LAB)) do
    Assert.equal(actor.surfaceId, 0)
    Assert.equal(actor.worldY, 0)
    Assert.isTrue(manager:isOccupied(LAB, actor.fieldX, actor.fieldZ, actor.surfaceId))
  end
  local elm = assert(manager:getById("map:61:object:0"))
  Assert.equal(elm.spriteId, 99)
  Assert.equal(elm.facing, "south")
  Assert.equal(elm.sourceEvent.eventFlag, 401)
  Assert.equal(elm.sourceEvent.scriptId, 1)
end

function T.no_visible_scenario_actor_stands_on_a_warp_cell(romFs)
  local reader = fieldDataFor(romFs)
  local eventState = FieldEventState.new()
  FieldScenario.apply(scenarioManifest, eventState, reader)
  for _, mapId in ipairs({ 60, LAB }) do
    local field = reader(mapId)
    local warpCells = {}
    for _, warp in ipairs(field.events.warps) do
      warpCells[warp.x .. ":" .. warp.z] = warp
    end
    for _, event in ipairs(field.events.objects) do
      -- The same visibility rule the manager applies: an object exists only
      -- while its event flag is clear. A visible actor on a warp cell would
      -- block a walking entry into the warp.
      if not eventState:isFlagSet(event.eventFlag) then
        Assert.isNil(warpCells[event.x .. ":" .. event.z],
          "map " .. mapId .. " visible object " .. event.objectEventId
            .. " stands on warp cell (" .. event.x .. "," .. event.z .. ")")
      end
    end
  end
end

function T.flag_toggles_remove_and_restore_elm_on_one_step(romFs)
  local manager, eventState = labSession(romFs)
  local elm = assert(manager:getById("map:61:object:0"))
  eventState:setFlag(elm.sourceEvent.eventFlag)
  manager:step(1)
  Assert.isNil(manager:getById("map:61:object:0"))
  Assert.isFalse(manager:isOccupied(LAB, elm.fieldX, elm.fieldZ, elm.surfaceId))
  eventState:clearFlag(elm.sourceEvent.eventFlag)
  manager:step(2)
  Assert.notNil(manager:getById("map:61:object:0"))
  Assert.isTrue(manager:isOccupied(LAB, elm.fieldX, elm.fieldZ, elm.surfaceId))
end

function T.repeated_lab_entry_keeps_identities_stable_and_visuals_balanced(romFs)
  local manager, eventState, assets, map = labSession(romFs)
  local baseline = assets:total()
  for _ = 1, 4 do
    manager:leaveMap(LAB)
    Assert.equal(assets:total(), 0)
    manager:enterMap(map, eventState)
    Assert.equal(assets:total(), baseline)
    Assert.equal(#manager:actorsOf(LAB), 2)
  end
  manager:dispose()
  Assert.equal(assets:total(), 0)
end

return T
