-- Interaction binding tests : the binding
-- manifest, trigger descriptors, interaction resolution order, the
-- interaction client's started/blocked/unmapped outcomes, the actor world
-- adapter contract, and the session-level script phase. The contract:
-- the target script IDs start from actual field interactions.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local WaitTicksTask = require("libs.engine.src.script.tasks.WaitTicksTask")
local Bindings = require("libs.engine.src.script.Bindings")
local ScriptActorWorld = require("libs.engine.src.script.ScriptActorWorld")
local ScriptInteractionClient = require("libs.engine.src.script.ScriptInteractionClient")
local FakeServices = require("tests.support.script.FakeServices")
local FieldSession = require("libs.engine.src.FieldSession")

local T = {}

local MANIFEST = {
  maps = {
    [57] = {
      objects = { obj_T20_gswoman1 = "new_bark.npc.woman_1" },
      backgrounds = {},
      coordinates = {},
    },
    [58] = {
      objects = { obj_T20R0101_doctor = "elms_lab.elm" },
      backgrounds = { [9] = "new_bark.lab_sign" },
      coordinates = {},
    },
  },
}

local function objectIntent(mapId, actorId, playerFacing)
  return {
    kind = "object",
    mapId = mapId,
    sourceFieldX = 4,
    sourceFieldZ = 6,
    targetFieldX = 4,
    targetFieldZ = 5,
    playerFacing = playerFacing or "north",
    object = { actorId = actorId, objectEventId = 3, spriteId = 1 },
  }
end

local function backgroundIntent(mapId, eventIndex, playerFacing)
  return {
    kind = "background",
    mapId = mapId,
    sourceFieldX = 4,
    sourceFieldZ = 6,
    targetFieldX = 6,
    targetFieldZ = 3,
    playerFacing = playerFacing or "south",
    background = { eventIndex = eventIndex, type = 1, direction = 4 },
  }
end

local function platform()
  local services = FakeServices.new()
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return { services = services, registry = registry, composition = composition, scheduler = scheduler }
end

local function script(id, steps)
  return S.script({ api = 1, id = id, steps = steps })
end

-- 1. Object binding resolves to the stable public script id and builds the
-- trigger descriptor.
T["object binding and trigger"] = function()
  local bindings = Bindings.new(MANIFEST)
  Assert.equal(bindings:scriptFor(57, "object", "obj_T20_gswoman1"), "new_bark.npc.woman_1")
  local hit = bindings:resolveIntent(objectIntent(57, "obj_T20_gswoman1", "north"), "north")
  local trigger = assert(hit).trigger
  Assert.equal(trigger.kind, "object")
  Assert.equal(trigger.mapId, 57)
  Assert.equal(trigger.objectId, "obj_T20_gswoman1")
  Assert.equal(trigger.scriptId, "new_bark.npc.woman_1")
  Assert.equal(trigger.selfActor, "obj_T20_gswoman1")
  Assert.equal(trigger.playerFacing, "north")
end

-- 2. Background binding: the exact background array index lives in the
-- manifest; public code uses the stable id.
T["background binding and trigger"] = function()
  local bindings = Bindings.new(MANIFEST)
  Assert.equal(bindings:scriptFor(58, "background", 9), "new_bark.lab_sign")
  local hit = bindings:resolveIntent(backgroundIntent(58, 9, "south"), "south")
  local trigger = assert(hit).trigger
  Assert.equal(trigger.kind, "background")
  Assert.equal(trigger.backgroundId, 9)
  Assert.equal(trigger.selfActor, nil)
  Assert.equal(trigger.scriptId, "new_bark.lab_sign")
end

-- 3. Unbound events resolve to nil (no-script event).
T["unbound event"] = function()
  local bindings = Bindings.new(MANIFEST)
  Assert.isNil(bindings:resolveIntent(objectIntent(58, "obj_unknown", "north"), "north"))
  Assert.isNil(bindings:resolveIntent(backgroundIntent(58, 0, "south"), "south"))
  Assert.isNil(bindings:scriptFor(57, "background", 0))
end

-- 4. All bound ids are enumerable.
T["bound script ids"] = function()
  local bindings = Bindings.new(MANIFEST)
  Assert.deepEqual(bindings:allScriptIds(), {
    "elms_lab.elm",
    "new_bark.lab_sign",
    "new_bark.npc.woman_1",
  })
end

-- 5. The interaction client starts a bound script in the trigger tick.
T["client starts script in trigger tick"] = function()
  local p = platform()
  local resource = script("new_bark.npc.woman_1", {
    S.setVar({ variable = "VAR_SCENE", value = 1 }),
    S.waitTicks({ ticks = 1 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local client = ScriptInteractionClient.new({
    bindings = Bindings.new(MANIFEST),
    compose = function(id)
      return p.composition:effective(id)
    end,
    scheduler = p.scheduler,
  })
  local result = client:consume(objectIntent(57, "obj_T20_gswoman1", "north"), 100)
  Assert.equal(result, "started")
  Assert.equal(
    p.services.world:getVar("VAR_SCENE"),
    1,
    "a newly resolved interaction may execute during its trigger tick"
  )
  local instance = assert(p.scheduler:instances()[1])
  Assert.equal(instance.trigger.scriptId, "new_bark.npc.woman_1")
  Assert.equal(instance.trigger.selfActor, "obj_T20_gswoman1")
end

-- 6. A second interaction while a foreground root owns the field is blocked.
T["interaction while locked"] = function()
  local p = platform()
  local resource = script("new_bark.npc.woman_1", {
    S.waitTicks({ ticks = 5 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local client = ScriptInteractionClient.new({
    bindings = Bindings.new(MANIFEST),
    compose = function(id)
      return p.composition:effective(id)
    end,
    scheduler = p.scheduler,
  })
  Assert.equal(client:consume(objectIntent(57, "obj_T20_gswoman1", "north"), 100), "started")
  Assert.equal(client:consume(objectIntent(57, "obj_T20_gswoman1", "north"), 101), "blocked")
end

-- 7. Unmapped intents report "unmapped" so the caller can fall through to a
-- fallback client.
T["unmapped intent falls through"] = function()
  local p = platform()
  local client = ScriptInteractionClient.new({
    bindings = Bindings.new(MANIFEST),
    compose = function(id)
      return p.composition:effective(id)
    end,
    scheduler = p.scheduler,
  })
  Assert.equal(client:consume(objectIntent(57, "obj_unmapped", "north"), 100), "unmapped")
  Assert.isNil(p.scheduler:foregroundEnvironmentId())
end

-- 8. A tombstoned script (composition resolves nil) behaves as unmapped.
T["removed script is unmapped"] = function()
  local p = platform()
  local resource = script("new_bark.npc.woman_1", { S.stop() })
  p.registry:installBase(resource.id, resource, "generated")
  p.registry:remove(resource.id, { modId = "mod.a" }, { priority = 10 })
  local client = ScriptInteractionClient.new({
    bindings = Bindings.new(MANIFEST),
    compose = function(id)
      return p.composition:effective(id)
    end,
    scheduler = p.scheduler,
  })
  Assert.equal(client:consume(objectIntent(57, "obj_T20_gswoman1", "north"), 100), "unmapped")
end

-- 9. Actor world adapter: the player is always present; snapshots are
-- read-only records; mutation operations reach the manager.
T["actor world adapter"] = function()
  local actors = {}
  actors.elm = { id = "elm", fieldX = 4, fieldZ = 5, facing = "north", visible = true }
  local manager = {
    getActor = function(self, id)
      return actors[id]
    end,
    getPosition = function(self, id)
      return { fieldX = actors[id].fieldX, fieldZ = actors[id].fieldZ, worldY = 0 }
    end,
    getFacing = function(self, id)
      return actors[id].facing
    end,
    show = function(self, id)
      actors[id].visible = true
    end,
    hide = function(self, id)
      actors[id].visible = false
    end,
    setPosition = function(self, id, position)
      actors[id].fieldX = position.fieldX
      actors[id].fieldZ = position.fieldZ
    end,
    setFacing = function(self, id, direction)
      actors[id].facing = direction
    end,
    setMovementType = function(self, id, movementType)
      actors[id].movementType = movementType
    end,
    setAnimationPaused = function(self, id, paused)
      actors[id].animationPaused = paused
    end,
    numericId = function(self, id)
      return actors[id] and 7 or nil
    end,
    actorIdForMapIndex = function()
      return nil
    end,
    cameraTargetId = function()
      return nil
    end,
    partnerId = function()
      return nil
    end,
  }
  local player = {
    position = function()
      return { fieldX = 10, fieldZ = 10, worldY = 0 }
    end,
    facing = function()
      return "south"
    end,
    gender = function()
      return 0
    end,
    name = function()
      return "Gold"
    end,
  }
  local world = ScriptActorWorld.new(manager, player)
  Assert.isTrue(world:exists("player"))
  Assert.isTrue(world:exists("elm"))
  Assert.isFalse(world:exists("ghost"))
  local snapshot = world:snapshot("elm")
  ---@cast snapshot table
  Assert.equal(snapshot.actorId, "elm")
  Assert.equal(snapshot.facing, "north")
  world:setFacing("elm", "east")
  world:hide("elm")
  Assert.equal(actors.elm.facing, "east")
  Assert.isFalse(actors.elm.visible)
  Assert.equal(world:getPosition("player").fieldX, 10)
end

-- 10. Missing actors through the runtime are attributed errors.
T["missing actor fault through binding path"] = function()
  local p = platform()
  local manager = {
    getActor = function()
      return nil
    end,
    getPosition = function()
      return nil
    end,
    getFacing = function()
      return nil
    end,
    show = function() end,
    hide = function() end,
    setPosition = function() end,
    setFacing = function() end,
    setMovementType = function() end,
    setAnimationPaused = function() end,
    numericId = function()
      return nil
    end,
    actorIdForMapIndex = function()
      return nil
    end,
    cameraTargetId = function()
      return nil
    end,
    partnerId = function()
      return nil
    end,
  }
  p.services.actors = ScriptActorWorld.new(manager, p.services.player) --[[@as FakeActors]]
  local resource = script("elms_lab.elm", {
    S.facePlayer({ actor = "self" }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local composed = assert(p.composition:effective(resource.id))
  local trigger = {
    kind = "object",
    mapId = 58,
    objectId = "obj_T20R0101_doctor",
    scriptId = resource.id,
    selfActor = "obj_T20R0101_doctor",
    playerFacing = "north",
  }
  p.scheduler:createForeground(composed, trigger, 100)
  p.scheduler:step(100, nil)
  local instance = assert(p.scheduler:instances()[1])
  Assert.equal(instance.status, "faulted")
  Assert.equal(instance.endReason, "SCRIPT_ACTOR_NOT_FOUND")
end

-- 11. Map transition cancellation: a warp cancels the foreground environment,
-- releasing locks and tasks.
T["map transition cancels scripts"] = function()
  local p = platform()
  local resource = script("new_bark.npc.woman_1", {
    S.lockAll(),
    S.waitTicks({ ticks = 5 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local composed = assert(p.composition:effective(resource.id))
  local instanceId = p.scheduler:createForeground(composed, {
    kind = "object",
    mapId = 57,
    scriptId = resource.id,
    selfActor = "obj_T20_gswoman1",
  }, 100)
  p.scheduler:step(100, nil)
  local envId = assert(p.scheduler:foregroundEnvironmentId())
  p.scheduler:cancelEnvironment(envId, "map transition")
  Assert.isNil(p.scheduler:foregroundEnvironmentId())
  Assert.equal(assert(p.scheduler:instance(instanceId)).status, "cancelled")
  Assert.equal(#p.scheduler:tasks(), 0)
end

-- 12. Session-level integration: with a script scheduler attached, the
-- session steps the script phase each tick and consumes the tick while a
-- foreground script owns the field (player movement suppressed).
T["session script phase"] = function()
  local p = platform()
  local resource = script("new_bark.npc.woman_1", {
    S.setVar({ variable = "VAR_SCENE", value = 1 }),
    S.waitTicks({ ticks = 1 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local client = ScriptInteractionClient.new({
    bindings = Bindings.new(MANIFEST),
    compose = function(id)
      return p.composition:effective(id)
    end,
    scheduler = p.scheduler,
  })
  local moved = 0
  local player = {
    fieldX = 4,
    fieldZ = 6,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function(self)
      moved = moved + 1
      self.motion = "idle"
      return false
    end,
  }
  local runtimeMap = { mapId = 57 }
  local camera = { updateFixed = function() end }
  local transition = { phase = "idle", locked = false, updateFixed = function() end }
  local input = {
    snapshot = function()
      return {}
    end,
    clearEdges = function() end,
  }
  local actors = { step = function() end }
  local session = FieldSession.new({
    versionId = "heartgold",
    currentMap = runtimeMap,
    player = player,
    camera = camera,
    transition = transition,
    input = input,
    actors = actors,
    scriptScheduler = p.scheduler,
    scriptClient = client,
    interactions = {
      resolve = function(_, snapshot)
        return objectIntent(57, "obj_T20_gswoman1", "north")
      end,
      consume = function()
        return false
      end,
    },
  })
  -- The script client starts the interaction and the tick is consumed: the
  -- player does not move while the foreground root owns the field.
  session:updateFixed({ actionPressed = true, heldDirection = "south" })
  Assert.equal(p.services.world:getVar("VAR_SCENE"), 1)
  Assert.equal(moved, 0, "player movement is suppressed while a script owns the field")
  Assert.equal(session.tick, 1)
  -- Once the script completes, the field is free again.
  session:updateFixed({})
  session:updateFixed({})
  Assert.isNil(p.scheduler:foregroundEnvironmentId())
end

-- 12b. A live foreground root locks player movement even before the script
-- has issued any explicit lock: foreground ownership is field ownership.
T["foreground root locks movement without an explicit lock"] = function()
  local p = platform()
  local resource = script("new_bark.npc.woman_1", {
    S.waitTicks({ ticks = 2 }),
    S.stop(),
  })
  p.registry:installBase(resource.id, resource, "generated")
  local composed = assert(p.composition:effective(resource.id))
  p.scheduler:createForeground(composed, nil, 100)
  Assert.isTrue(p.scheduler:playerMovementLocked(), "a live foreground root suppresses movement without lock_player")
  p.scheduler:step(100, nil)
  p.scheduler:step(101, nil)
  p.scheduler:step(102, nil)
  p.scheduler:step(103, nil)
  Assert.isNil(p.scheduler:foregroundEnvironmentId())
  Assert.isFalse(p.scheduler:playerMovementLocked(), "the field unlocks when the foreground root ends")
end

return T
