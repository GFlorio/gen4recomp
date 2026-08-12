-- ROM-conformance save-resume facts: a captured save restores
-- field location, avatar, and the full event store on both target maps, and a
-- resumed event store still hides the scenario-seeded story actors. There is
-- only one save schema, so no version handling exists. Everything runs
-- against real ROM terrain via the shared runtime-map compiler.

local Assert = require("tests.support.Assert")
local FieldActorManager = require("libs.engine.src.FieldActorManager")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldScenario = require("libs.engine.src.FieldScenario")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")
local WarpSystem = require("libs.engine.src.WarpSystem")
local actorManifest = require("romdump.src.config.FieldActors")
local scenarioManifest = require("data.manifests.field_scenario")

local T = {}

local LAB = 61
local TOWN = 60

local POLICY = {
  variableSprites = {
    first = actorManifest.variableSpriteRange.first,
    last = actorManifest.variableSpriteRange.last,
    variableBase = actorManifest.variableVarBase,
  },
}

local function mapsById(romFs)
  return {
    [LAB] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"),
    [TOWN] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK"),
  }
end

local function scenarioReader(maps)
  return function(mapId)
    return assert(maps[mapId], "scenario map " .. mapId .. " not compiled").fieldData
  end
end

-- The surface the runtime would resolve for the player at a field cell.
local function sampleAt(map, fieldX, fieldZ)
  local localX, localZ = fieldX - map.coordinateOrigin.x, fieldZ - map.coordinateOrigin.z
  return assert(SurfaceResolver.new(map.terrain):resolve({
    localX = localX + 0.5,
    localZ = localZ + 0.5,
    currentY = 0,
  }))
end

local function fakeAssets()
  return {
    knows = function()
      return true
    end,
    acquire = function(_, spriteId)
      return { spriteId = spriteId, visual = { spriteId = spriteId } }
    end,
    release = function() end,
  }
end

function T.field_state_avatar_and_events_resume_on_both_target_maps(romFs, versionId)
  local maps = mapsById(romFs)
  local loader = {
    load = function(_, mapId)
      return assert(maps[mapId], "map " .. mapId)
    end,
  }
  local cases = {
    -- The demo spawn tile: a real warp cell, so restore must also arm the
    -- arrival suppression the runtime needs.
    { map = maps[LAB], fieldX = 4, fieldZ = 14, expectsWarp = true },
    -- One walkable town cell clear of any warp.
    { map = maps[TOWN], fieldX = 684, fieldZ = 394, expectsWarp = false },
  }
  for _, case in ipairs(cases) do
    local map = case.map
    Assert.isTrue(
      WarpSystem.findAt(map, case.fieldX, case.fieldZ) ~= nil == case.expectsWarp,
      "the case cell warp expectation must hold"
    )
    local sample = sampleAt(map, case.fieldX, case.fieldZ)
    local state = FieldEventState.new()
    FieldScenario.apply(scenarioManifest, state, scenarioReader(maps))
    state:setVar(0x4020, 1)
    local session = {
      versionId = versionId,
      currentMap = map,
      player = {
        motion = "idle",
        fieldX = case.fieldX,
        fieldZ = case.fieldZ,
        worldY = sample.worldY,
        surfaceId = sample.surfaceId,
        facing = "south",
      },
      transition = { phase = "idle" },
    }
    local serialized = state:serialize()
    local saved = FieldSave.capture(session, {
      avatarId = "heroine",
      scenario = scenarioManifest.id,
      world = { flags = serialized.flags, variables = serialized.vars, objects = {}, rng = {} },
    })
    local restored = assert(FieldSave.restore(saved, loader, versionId))
    Assert.equal(restored.runtimeMap.mapId, map.mapId)
    Assert.equal(restored.fieldX, case.fieldX)
    Assert.equal(restored.fieldZ, case.fieldZ)
    Assert.equal(restored.surfaceId, sample.surfaceId)
    Assert.equal(restored.worldY, sample.worldY)
    Assert.equal(restored.facing, "south")
    Assert.equal(restored.avatar, "heroine", "the persisted avatar choice survives")
    Assert.equal(restored.scenario, scenarioManifest.id)
    Assert.deepEqual(restored.world, saved.world)
    if case.expectsWarp then
      Assert.notNil(restored.suppression)
    else
      Assert.isNil(restored.suppression)
    end
  end
end

function T.a_resumed_event_store_keeps_scenario_actors_hidden(romFs)
  local maps = mapsById(romFs)
  local state = FieldEventState.new()
  FieldScenario.apply(scenarioManifest, state, scenarioReader(maps))
  local sample = sampleAt(maps[LAB], 4, 14)
  local session = {
    versionId = "heartgold",
    currentMap = maps[LAB],
    player = {
      motion = "idle",
      fieldX = 4,
      fieldZ = 14,
      worldY = sample.worldY,
      surfaceId = sample.surfaceId,
      facing = "south",
    },
    transition = { phase = "idle" },
  }
  local serialized = state:serialize()
  local saved = FieldSave.capture(session, {
    avatarId = "hero",
    scenario = scenarioManifest.id,
    world = { flags = serialized.flags, variables = serialized.vars, objects = {}, rng = {} },
  })
  local restored = assert(FieldSave.restore(saved, {
    load = function(_, mapId)
      return assert(maps[mapId])
    end,
  }, "heartgold"))
  local revived = FieldEventState.new({
    flags = restored.world.flags,
    vars = restored.world.variables,
  })
  local manager = FieldActorManager.new({ assets = fakeAssets(), policy = POLICY })
  manager:enterMap(maps[LAB], revived)
  Assert.notNil(manager:getById("map:61:object:0"), "Elm stays visible on resume")
  Assert.notNil(manager:getById("map:61:object:2"), "the aide stays visible on resume")
  Assert.isNil(manager:getById("map:61:object:1"), "the officer stays hidden on resume")
  Assert.isNil(manager:getById("map:61:object:3"), "the friend stays hidden on resume")
  manager:dispose()
end

return require("tests.rom.support.RomSuite").fromFacts(T)
