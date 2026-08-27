-- ROM-conformance save-resume facts: a captured save restores
-- field location, avatar, and the full event store on both target maps. There
-- is only one save schema, so no version handling exists. Everything runs
-- against real ROM terrain via the shared runtime-map compiler.

local Assert = require("tests.support.Assert")
local FieldEventState = require("libs.engine.src.FieldEventState")
local FieldSave = require("libs.engine.src.FieldSave")
local PlayerDataContext = require("tests.support.PlayerDataContext")
local RomRuntimeMap = require("tests.support.RomRuntimeMap")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")
local WarpSystem = require("libs.engine.src.WarpSystem")

local T = {}

local LAB = 61
local TOWN = 60

local function mapsById(romFs)
  return {
    [LAB] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK_ELMS_LAB_1F"),
    [TOWN] = RomRuntimeMap.compile(romFs, "MAP_NEW_BARK"),
  }
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

function T.field_state_avatar_and_events_resume_on_both_target_maps(romFs, versionId)
  local maps = mapsById(romFs)
  local loader = {
    load = function(_, mapId)
      return assert(maps[mapId], "map " .. mapId)
    end,
  }
  local cases = {
    -- The lab entry spawn tile: a real warp cell, so restore must also arm the
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
    ---@cast session FieldSave.Session
    local serialized = state:serialize()
    local saved = FieldSave.capture(session, {
      avatarId = "heroine",
      world = { flags = serialized.flags, variables = serialized.vars, objects = {}, rng = { state = 1, calls = 0 } },
      scriptsBucket = {},
      auxiliaryUi = { requested = "shown", state = "shown" },
      playerData = {
        profile = { name = "GOLD", gender = 0, trainerId = 0 },
        options = { textFrame = 0, textSpeed = "mid" },
      },
    })
    local restored =
      assert(FieldSave.restore(saved, loader, versionId, { playerDataContext = PlayerDataContext.new() }))
    Assert.equal(restored.runtimeMap.mapId, map.mapId)
    Assert.equal(restored.fieldX, case.fieldX)
    Assert.equal(restored.fieldZ, case.fieldZ)
    Assert.equal(restored.surfaceId, sample.surfaceId)
    Assert.equal(restored.worldY, sample.worldY)
    Assert.equal(restored.facing, "south")
    Assert.equal(restored.avatar, "heroine", "the persisted avatar choice survives")
    Assert.deepEqual(restored.world, saved.world)
    if case.expectsWarp then
      Assert.notNil(restored.suppression)
    else
      Assert.isNil(restored.suppression)
    end
  end
end

return require("tests.rom.support.RomSuite").fromFacts(T)
