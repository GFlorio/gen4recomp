-- Field arbitration contracts for collision-gated input, inert script-zero
-- intents, strict binding audit, and approach-derived escalator facing.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local BindingAudit = require("libs.engine.src.script.BindingAudit")
local Bindings = require("libs.engine.src.script.Bindings")
local FieldEventResolver = require("libs.engine.src.FieldEventResolver")
local FieldInteractionResolver = require("libs.engine.src.FieldInteractionResolver")
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")
local TilePermissions = require("tests.support.TilePermissions")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")

local T = {}
local BEHAVIOR = MetatileBehavior.BEHAVIOR

local function map(warpBehavior, tiles)
  return {
    mapId = 60,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { { index = 0, x = 4, z = 4 } } } },
    collision = TilePermissions.new(tiles or { ["4:4"] = { behavior = warpBehavior } }),
  }
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err))
  Assert.equal(err.code, code)
end

local function zeroIntent(kind)
  return {
    kind = kind,
    mapId = 60,
    sourceFieldX = 4,
    sourceFieldZ = 5,
    targetFieldX = 4,
    targetFieldZ = 4,
    playerFacing = "north",
    scriptId = 0,
    tick = 1,
    object = kind == "object" and { actorId = "map:60:object:0", objectEventId = 0, spriteId = 1 } or nil,
    background = kind == "background" and { eventIndex = 0, type = 1, direction = 4 } or nil,
    coordinate = kind == "coordinate" and { index = 0 } or nil,
    coordinateId = kind == "coordinate" and 0 or nil,
  }
end

local function fieldData(objects, backgrounds, coordinates)
  return { mapId = 60, events = { objects = objects, background = backgrounds, coordinates = coordinates } }
end

function T.input_path_requires_the_facing_collision_gate_after_ladder_check()
  for _, case in ipairs({
    { behavior = BEHAVIOR.WARP_ENTRANCE_SOUTH, direction = "south" },
    { behavior = BEHAVIOR.WARP_ENTRANCE_EAST, direction = "east" },
    { behavior = BEHAVIOR.WARP_ENTRANCE_WEST, direction = "west" },
  }) do
    local delta =
      { north = { x = 0, z = -1 }, south = { x = 0, z = 1 }, east = { x = 1, z = 0 }, west = { x = -1, z = 0 } }
    local d = delta[case.direction]
    local unblocked =
      map(case.behavior, { ["4:4"] = { behavior = case.behavior }, [(4 + d.x) .. ":" .. (4 + d.z)] = {} })
    Assert.isNil(TransitionTrigger.inputPath(unblocked, 4, 4, case.direction))
    local blocked = map(
      case.behavior,
      { ["4:4"] = { behavior = case.behavior }, [(4 + d.x) .. ":" .. (4 + d.z)] = { blocked = true } }
    )
    Assert.notNil(TransitionTrigger.inputPath(blocked, 4, 4, case.direction))
  end

  local ladder = map(BEHAVIOR.LADDER_NORTH)
  Assert.notNil(TransitionTrigger.inputPath(ladder, 4, 4, "north"))
end

function T.coordinate_and_passive_sign_resolvers_emit_raw_zero()
  local state = {
    getVar = function()
      return 7
    end,
  }
  local player = { fieldX = 4, fieldZ = 4, facing = "north" }
  local runtimeMap = {
    mapId = 60,
    fieldData = {
      events = {
        coordinates = {
          { index = 0, scriptId = 0, x = 4, z = 4, width = 1, height = 1, variableId = 2, requiredValue = 7 },
        },
        background = { { index = 0, scriptId = 0, type = 1, x = 4, z = 3, directionRaw = 4 } },
      },
    },
  }
  Assert.equal(assert(FieldEventResolver.resolveCoordinate(runtimeMap, player, state)).scriptId, 0)
  Assert.equal(assert(FieldEventResolver.resolvePassiveSign(runtimeMap, player)).scriptId, 0)
end

function T.script_zero_intents_share_one_canonical_binding_without_masking_nonzero_missing_bindings()
  local bindings = Bindings.new({ maps = { [60] = { objects = {}, backgrounds = {}, coordinates = {} } } })
  local object = assert(bindings:resolveIntent(zeroIntent("object"), "north"))
  local background = assert(bindings:resolveIntent(zeroIntent("background"), "north"))
  local coordinate = assert(bindings:resolveIntent(zeroIntent("coordinate"), "north"))
  Assert.equal(object.scriptId, background.scriptId)
  Assert.equal(object.scriptId, coordinate.scriptId)
  Assert.isFalse(object.scriptId == 0)
  local missingNonzero = zeroIntent("object")
  missingNonzero.scriptId = 9
  Assert.isNil(bindings:resolveIntent(missingNonzero, "north"))
end

function T.binding_audit_is_zero_aware_but_strict_for_nonzero_and_hidden_items()
  local manifest = { maps = { [60] = { objects = {}, backgrounds = {}, coordinates = {} } } }
  Assert.isTrue(BindingAudit.check(manifest, function()
    return fieldData({ { objectEventId = 0, scriptId = 0 } }, { { index = 0, type = 1, scriptId = 0 } }, {})
  end))
  throwsCode("SCRIPT_BINDING_AUDIT_INCOMPLETE", function()
    BindingAudit.check(manifest, function()
      return fieldData({ { objectEventId = 0, scriptId = 9 } }, {}, {})
    end)
  end)
  throwsCode("SCRIPT_BINDING_AUDIT_HIDDEN_ITEM_BOUND", function()
    BindingAudit.check(
      { maps = { [60] = { objects = {}, backgrounds = { [0] = "hidden" }, coordinates = {} } } },
      function()
        return fieldData({}, { { index = 0, type = 2, scriptId = 8000 } }, {})
      end
    )
  end)
end

function T.escalator_destination_facing_follows_approach_and_flip_policy()
  for _, case in ipairs({
    { behavior = BEHAVIOR.ESCALATOR, approach = "east", expected = "east" },
    { behavior = BEHAVIOR.ESCALATOR, approach = "west", expected = "west" },
    { behavior = BEHAVIOR.ESCALATOR_FLIP_FACE, approach = "east", expected = "west" },
    { behavior = BEHAVIOR.ESCALATOR_FLIP_FACE, approach = "west", expected = "east" },
  }) do
    local trigger = assert(TransitionTrigger.stepPath(map(case.behavior), 4, 4, case.approach)) --[[@as TransitionTrigger]]
    Assert.equal(trigger.destinationFacing, case.expected)
  end
end

return { tests = T }
