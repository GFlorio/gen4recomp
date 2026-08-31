-- FieldObjectActor tests freeze the immutable-source / mutable-runtime split,
-- the stable actor identity, and the tokenized temporary facing override.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldObjectActor = require("libs.hgss.src.field.FieldObjectActor")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
  return err
end

local function sourceEvent(overrides)
  local event = {
    index = 0,
    objectEventId = 0,
    spriteId = 99,
    movementType = "stationary",
    type = 0,
    eventFlag = 401,
    scriptId = 1,
    facingDirection = "south",
    facingDirectionRaw = 1,
    param0 = 0,
    param1 = 0,
    param2 = 0,
    xRange = 0,
    yRange = 0,
    x = 6,
    z = 5,
    y = 0,
  }
  for key, value in pairs(overrides or {}) do
    event[key] = value
  end
  return event
end

local function actor(overrides, optsOverrides)
  local opts = {
    mapId = 61,
    sourceEvent = sourceEvent(overrides),
    fieldX = 6,
    fieldZ = 5,
    surfaceId = 0,
    worldX = 6.5,
    worldY = 0,
    worldZ = 5.5,
  }
  for key, value in pairs(optsOverrides or {}) do
    rawset(opts, key, value)
  end
  return FieldObjectActor.new(opts)
end

function T.actor_id_is_map_and_object_identity()
  Assert.equal(FieldObjectActor.actorId(61, 3), "map:61:object:3")
  Assert.equal(actor().actorId, "map:61:object:0")
end

function T.runtime_state_starts_from_the_source_record()
  local a = actor()
  Assert.equal(a.spriteId, 99)
  Assert.equal(a.initialFacing, "south")
  Assert.equal(a.facing, "south")
  Assert.equal(a.pose, "idle")
  Assert.equal(a.poseTick, 0)
  Assert.isTrue(a.visible)
  Assert.isTrue(a.solid)
  Assert.equal(a.movementType, "stationary")
  Assert.isNil(a.interactionFacingOverride)
end

-- A zero interaction script is the source's inert map-object marker for
-- A-button interaction, not a solidity signal: a visible zero-script actor
-- still follows source collision semantics unless the event explicitly opts
-- out.
function T.zero_script_actors_remain_solid_by_default()
  Assert.isTrue(actor({ scriptId = 0 }).solid)
end

function T.explicit_non_solid_semantic_is_honored_regardless_of_script_id()
  Assert.isFalse(actor({ scriptId = 0 }, { solid = false }).solid)
  Assert.isFalse(actor({ scriptId = 5 }, { solid = false }).solid)
end

function T.unknown_source_facing_is_rejected()
  throwsCode("ACTOR_FACING_INVALID", function()
    actor({ facingDirection = "unknown", facingDirectionRaw = 9 })
  end)
end

function T.facing_override_applies_and_restores()
  local a = actor()
  local token = a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  Assert.equal(a.facing, "north")
  Assert.equal(a.initialFacing, "south")
  a:releaseFacingOverride(token)
  Assert.equal(a.facing, "south")
  Assert.isNil(a.interactionFacingOverride)
end

function T.override_restores_the_facing_it_replaced_not_the_source_facing()
  local a = actor()
  a.facing = "east"
  local token = a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  a:releaseFacingOverride(token)
  Assert.equal(a.facing, "east")
end

function T.nested_overrides_are_rejected()
  local a = actor()
  a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  throwsCode("ACTOR_OVERRIDE_OWNER_MISMATCH", function()
    a:pushFacingOverride({ owner = "someone-else", facing = "west" })
  end)
end

function T.releasing_a_foreign_token_is_rejected()
  local a = actor()
  a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  throwsCode("ACTOR_OVERRIDE_OWNER_MISMATCH", function()
    a:releaseFacingOverride({})
  end)
  Assert.equal(a.facing, "north")
end

function T.releasing_twice_is_rejected()
  local a = actor()
  local token = a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  a:releaseFacingOverride(token)
  throwsCode("ACTOR_OVERRIDE_OWNER_MISMATCH", function()
    a:releaseFacingOverride(token)
  end)
end

function T.clear_facing_override_is_unconditional_and_idempotent()
  local a = actor()
  a:pushFacingOverride({ owner = "pre-script-dialogue", facing = "north" })
  a:clearFacingOverride()
  a:clearFacingOverride()
  Assert.equal(a.facing, "south")
end

return { tests = T }
