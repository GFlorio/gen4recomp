-- Interaction binding tests : the binding
-- manifest, trigger descriptors, interaction resolution order, the
-- interaction client's started/blocked/unmapped outcomes, the actor world
-- adapter contract, and the session-level script phase. The contract:
-- the target script IDs start from actual field interactions.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local WaitTicksTask = require("libs.engine.src.script.tasks.WaitTicksTask")
---@cast WaitTicksTask TaskImplementation
local Bindings = require("libs.engine.src.script.Bindings")
local ScriptActorWorld = require("libs.engine.src.script.ScriptActorWorld")
local ScriptInteractionClient = require("libs.engine.src.script.ScriptInteractionClient")
local FakeServices = require("tests.support.script.FakeServices")
local FieldSession = require("libs.engine.src.FieldSession")
local FieldEventResolver = require("libs.engine.src.FieldEventResolver")
local FieldEventState = require("libs.engine.src.FieldEventState")

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

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected a raised error")
  Assert.isTrue(Errors.is(err), "expected Errors object, got: " .. tostring(err))
  ---@cast err Errors.Error
  Assert.equal(err.code, code)
  return err
end

---@param mapId integer
---@param actorId string
---@param playerFacing FieldDirection
---@return InteractionIntent
local function objectIntent(mapId, actorId, playerFacing)
  return {
    kind = "object",
    mapId = mapId,
    sourceFieldX = 4,
    sourceFieldZ = 6,
    targetFieldX = 4,
    targetFieldZ = 5,
    sourceSurfaceId = 0,
    playerFacing = playerFacing or "north",
    scriptId = 1,
    tick = 0,
    object = { actorId = actorId, objectEventId = 3, spriteId = 1 },
  } --[[@as InteractionIntent]]
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

T["coordinate binding and trigger"] = function()
  local bindings = Bindings.new({
    maps = { [60] = { objects = {}, backgrounds = {}, coordinates = { [1] = "landing.script" } } },
  })
  local hit = bindings:resolveIntent({
    kind = "coordinate",
    mapId = 60,
    coordinateId = 1,
    coordinate = { index = 1 },
    sourceFieldX = 688,
    sourceFieldZ = 392,
    playerFacing = "west",
  }, "west")
  local trigger = assert(hit).trigger
  Assert.equal(trigger.kind, "coordinate")
  Assert.equal(trigger.mapId, 60)
  Assert.equal(trigger.coordinateId, 1)
  Assert.equal(trigger.scriptId, "landing.script")
  Assert.equal(trigger.playerFacing, "west")
  Assert.isNil(trigger.backgroundId)
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

-- 5. The manifest loader is strict: a missing maps array is a schema error,
-- never an empty binding set.
T["manifest without maps is rejected"] = function()
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({})
  end)
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({ maps = "not a table" })
  end)
end

-- 6. Every bound map must carry its required objects and backgrounds arrays:
-- a missing array is a schema error, never an implicit empty one.
T["map without required binding arrays is rejected"] = function()
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({ maps = { [57] = { backgrounds = {}, coordinates = {} } } })
  end)
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({ maps = { [57] = { objects = {}, coordinates = {} } } })
  end)
end

-- 7. Only dispatched trigger kinds may be bound. The coordinate and
-- map-lifecycle kinds have no dispatcher: carrying one is a schema error at
-- load, not data the loader silently accepts.
T["undispatched trigger kinds are rejected at load"] = function()
  for _, section in ipairs({ "map_init", "map_enter", "map_resume" }) do
    throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
      Bindings.new({ maps = { [57] = { objects = {}, backgrounds = {}, coordinates = {}, [section] = {} } } })
    end)
  end
end

-- 8. Binding keys and targets must have the required types: string object
-- keys, non-negative integer background keys, string targets, integer map
-- ids.
T["invalid binding key and target types are rejected"] = function()
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({ maps = { [57] = { objects = { [0] = "a" }, backgrounds = {}, coordinates = {} } } })
  end)
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({ maps = { [57] = { objects = {}, backgrounds = { [-1] = "a" }, coordinates = {} } } })
  end)
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({ maps = { [57] = { objects = {}, backgrounds = { [0.5] = "a" }, coordinates = {} } } })
  end)
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({ maps = { [57] = { objects = { ["map:57:object:0"] = 7 }, backgrounds = {}, coordinates = {} } } })
  end)
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({ maps = { ["57"] = { objects = {}, backgrounds = {}, coordinates = {} } } })
  end)
end

-- 9. An object binding key identifies one event and may not repeat across the
-- manifest: the same key bound twice is a duplicate, the same key bound to
-- two targets is a conflict.
T["duplicate and conflicting bindings are rejected"] = function()
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({
      maps = {
        [57] = { objects = { ["map:57:object:0"] = "a" }, backgrounds = {}, coordinates = {} },
        [60] = { objects = { ["map:57:object:0"] = "a" }, backgrounds = {}, coordinates = {} },
      },
    })
  end)
  throwsCode("SCRIPT_BINDING_MANIFEST_INVALID", function()
    Bindings.new({
      maps = {
        [57] = { objects = { ["map:57:object:0"] = "a" }, backgrounds = {}, coordinates = {} },
        [60] = { objects = { ["map:57:object:0"] = "b" }, backgrounds = {}, coordinates = {} },
      },
    })
  end)
end

-- 10. The interaction client starts a bound script in the trigger tick.
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
  Assert.equal(result, ScriptInteractionClient.RESULTS.started)
  Assert.equal(
    p.services.world:getVar("VAR_SCENE"),
    1,
    "a newly resolved interaction may execute during its trigger tick"
  )
  local instance = assert(p.scheduler:instances()[1])
  Assert.equal(instance.trigger.scriptId, "new_bark.npc.woman_1")
  Assert.equal(instance.trigger.selfActor, "obj_T20_gswoman1")
end

-- 11. A second interaction while a foreground root owns the field is blocked.
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
  Assert.equal(
    client:consume(objectIntent(57, "obj_T20_gswoman1", "north"), 100),
    ScriptInteractionClient.RESULTS.started
  )
  Assert.equal(
    client:consume(objectIntent(57, "obj_T20_gswoman1", "north"), 101),
    ScriptInteractionClient.RESULTS.blocked
  )
end

-- 12. Unmapped intents report "unmapped" so the caller can fall through to a
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
  Assert.equal(client:consume(objectIntent(57, "obj_unmapped", "north"), 100), ScriptInteractionClient.RESULTS.unmapped)
  Assert.isNil(p.scheduler:foregroundEnvironmentId())
end

-- 13. Actor world adapter: the player is always present; snapshots are
-- read-only records; mutation operations reach the manager.
T["actor world adapter"] = function()
  local actors = {}
  actors.elm = { id = "elm", fieldX = 4, fieldZ = 5, facing = "north", visible = true, mapId = 61 }
  local manager = {
    getActor = function(_, id)
      return actors[id]
    end,
    getPosition = function(_, id)
      return { fieldX = actors[id].fieldX, fieldZ = actors[id].fieldZ, worldY = 0 }
    end,
    getFacing = function(_, id)
      return actors[id].facing
    end,
    show = function(_, id)
      actors[id].visible = true
    end,
    hide = function(_, id)
      actors[id].visible = false
    end,
    setPosition = function(_, id, position)
      actors[id].fieldX = position.fieldX
      actors[id].fieldZ = position.fieldZ
    end,
    setFacing = function(_, id, direction)
      actors[id].facing = direction
    end,
    setMovementType = function(_, id, movementType)
      actors[id].movementType = movementType
    end,
    setAnimationPaused = function(_, id, paused)
      actors[id].animationPaused = paused
    end,
    numericId = function(_, id)
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
  ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
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
  Assert.equal(snapshot.mapId, 61, "the snapshot carries the actor's map id")
  Assert.equal(snapshot.facing, "north")
  world:setFacing("elm", "east")
  world:hide("elm")
  Assert.equal(actors.elm.facing, "east")
  Assert.isFalse(actors.elm.visible)
  Assert.equal(world:getPosition("player").fieldX, 10)
end

-- 15. Missing actors through the runtime are attributed errors.
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
  local fault = assert(p.services.events:eventFor("script.error", "script-00000001"))
  Assert.equal(fault.code, "SCRIPT_ACTOR_NOT_FOUND")
end

-- 16. Map transition cancellation: a warp cancels the foreground environment,
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
  local ended = assert(p.services.events:eventFor("script.ended", instanceId))
  Assert.isFalse(ended.completed)
  Assert.equal(ended.reason, "map transition")
  Assert.equal(#p.scheduler:tasks(), 0)
end

-- 17. Session-level integration: with a script scheduler attached, the
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
  ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
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
    collapseRenderInterpolation = function() end,
  } --[[@as FieldPlayer]]
  ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
  local runtimeMap = {
    mapId = 57,
    -- Mirrors the simulation-only aggregate: no presentation runtimes, so the
    -- map clock entry is a safe no-op.
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
  ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
  local camera = {
    updateFixed = function() end,
    collapseRenderInterpolation = function() end,
  } --[[@as FieldCamera]]
  ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("binding fixture never starts a warp", 2)
    end,
  } --[[@as FieldTransition]]
  ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
  local input = {
    snapshot = function()
      return {}
    end,
    clearEdges = function() end,
  } --[[@as FieldInput]]
  ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
  local actors = { step = function() end } --[[@as FieldActorManager]]
  ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
  local dialogue = {
    isModal = function()
      return false
    end,
  } --[[@as FieldDialogueController]]
  ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
  local menuHost = {
    isModal = function()
      return false
    end,
    advance = function() end,
  } --[[@as FieldMenuHost]]
  local contextChoice = {
    isActive = function()
      return false
    end,
  }
  local session = FieldSession.new({
    versionId = "heartgold",
    currentMap = runtimeMap --[[@as RuntimeFieldMap]],
    player = player --[[@as FieldPlayer]],
    fieldEntranceIndicator = { updateFixed = function() end },
    camera = camera --[[@as FieldCamera]],
    transition = transition --[[@as FieldTransition]],
    input = input --[[@as FieldInput]],
    actors = actors --[[@as FieldActorManager]],
    scriptScheduler = p.scheduler,
    scriptClient = client,
    interactions = {
      resolve = function(_)
        return objectIntent(57, "obj_T20_gswoman1", "north")
      end,
    },
    eventResolver = FieldEventResolver,
    eventState = FieldEventState.new(),
    dialogue = dialogue --[[@as FieldDialogueController]],
    menuHost = menuHost --[[@as FieldMenuHost]],
    contextChoice = contextChoice,
    ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
    signpost = {
      isModal = function()
        return false
      end,
    },
    ---@diagnostic disable-next-line: missing-fields -- focused FieldSession test double
    applicationHost = {
      isActive = function()
        return false
      end,
      updateFixed = function() end,
      requestOpen = function() end,
      takeReopen = function()
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

-- 18. A live foreground root locks player movement even before the script
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

return { tests = T }
