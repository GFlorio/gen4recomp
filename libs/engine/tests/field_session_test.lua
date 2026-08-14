-- Fixed-step session tests prove deterministic tick counts, catch-up capping,
-- and that the camera consumes the player's continuous 3D target.

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldPlayerVisual = require("libs.engine.src.FieldPlayerVisual")
local FieldSession = require("libs.engine.src.FieldSession")
local ScriptInteractionClient = require("libs.engine.src.script.ScriptInteractionClient")
local TerrainSurface = require("libs.engine.src.TerrainSurface")
local TilePermissions = require("tests.support.TilePermissions")

local T = {}

-- Complete fakes for the collaborators FieldSession requires at
-- construction: an idle transition (never completes, never locks, never
-- starts a warp), an input that snapshots nothing, and a manager that steps
-- no actors.
local function idleTransition()
  return {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("idle transition must never start a warp", 2)
    end,
  }
end

local function idleInput()
  return {
    snapshot = function()
      return {}
    end,
    uiSnapshot = function()
      return {}
    end,
    clearEdges = function() end,
  }
end

-- The application-host boundary the session steps: closed by default, with
-- the tick ownership and open/reopen surfaces the session calls.
local function applicationHostFake(overrides)
  local host = {
    active = false,
    openedTicks = {},
    reopenRequests = 0,
    updateCalls = 0,
    events = nil,
    activeWhileStepped = false,
  }
  function host:isActive()
    return self.active
  end
  function host:updateFixed(tick, uiInput)
    self.updateCalls = self.updateCalls + 1
    self.events = uiInput
  end
  function host:requestOpen(tick)
    self.openedTicks[#self.openedTicks + 1] = tick
    self.active = true
  end
  function host:requestReopen()
    self.reopenRequests = self.reopenRequests + 1
  end
  function host:takeReopen(tick)
    if self.reopenRequests > 0 then
      self.reopenRequests = self.reopenRequests - 1
      self.openedTicks[#self.openedTicks + 1] = tick
      self.active = true
      return true
    end
    return false
  end
  for key, value in pairs(overrides or {}) do
    host[key] = value
  end
  return host
end

local function idleActors()
  return { step = function() end }
end

local function defaultPlayer()
  return {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
  }
end

-- Every collaborator the production runtime supplies is required at
-- construction; these defaults implement the full required interface so a
-- fixture overrides only the collaborators it exercises. The default map
-- carries empty warp events so a pressed direction reaches the warp check
-- safely.
local function baseOptions(overrides)
  local options = {
    versionId = "heartgold",
    currentMap = {
      mapId = 61,
      fieldData = { events = { warps = {} } },
      -- Mirrors the simulation-only aggregate: no presentation runtimes, so
      -- the map clock entry is a safe no-op.
      updateAnimated = function() end,
    },
    player = defaultPlayer(),
    camera = { updateFixed = function() end },
    transition = idleTransition(),
    actors = idleActors(),
    input = idleInput(),
    dialogue = {
      isModal = function()
        return false
      end,
    },
    scriptScheduler = {
      step = function() end,
      playerMovementLocked = function()
        return false
      end,
    },
    scriptClient = { consume = function() end },
    menuHost = {
      isModal = function()
        return false
      end,
      advance = function() end,
    },
    contextChoice = {
      isActive = function()
        return false
      end,
    },
    signpost = {
      isModal = function()
        return false
      end,
    },
    applicationHost = applicationHostFake(),
    interactions = {
      resolve = function()
        return nil
      end,
    },
  }
  for key, value in pairs(overrides) do
    options[key] = value
  end
  return options
end

local function session()
  local targets = {}
  local camera = {
    updateFixed = function(_, target)
      targets[#targets + 1] = { x = target.x, y = target.y, z = target.z }
    end,
  }
  local player = {
    worldX = 1.25,
    worldY = 2.5,
    worldZ = 3.75,
    updateFixed = function()
      return false
    end,
  }
  return FieldSession.new(baseOptions({ player = player, camera = camera })), targets
end

function T.actor_only_construction_is_rejected()
  local actor = { worldX = 1.25, worldY = 2.5, worldZ = 3.75 }
  local camera = { updateFixed = function() end }
  -- Intentional: the obsolete actor-only options shape must be rejected by the
  -- constructor's required-player contract.
  local options = {
    versionId = "heartgold",
    currentMap = { mapId = 61 },
    actor = actor,
    camera = camera,
  } --[[@as any]]
  local ok, err = pcall(FieldSession.new, options)
  Assert.isFalse(ok, "a session must require the player, not fall back to an actor option: " .. tostring(err))
end

function T.player_is_used_as_the_session_player()
  local player = {
    worldX = 1.25,
    worldY = 2.5,
    worldZ = 3.75,
    updateFixed = function() end,
  }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new(baseOptions({ player = player, camera = camera }))
  Assert.equal(s.player, player)
  Assert.deepEqual(s:actorTarget(), { x = 1.25, y = 2.5, z = 3.75 })
end

-- The transition, input, and actor manager are tick-path collaborators every
-- production session supplies; construction must require them instead of
-- letting a session run with half its tick machinery missing. The dialogue,
-- script scheduler/client, menu host, context choice, and interaction
-- resolver complete the production composition set and are required the same
-- way.
function T.required_collaborators_are_validated_at_construction()
  local required = {
    "versionId",
    "currentMap",
    "player",
    "camera",
    "transition",
    "actors",
    "input",
    "dialogue",
    "scriptScheduler",
    "scriptClient",
    "menuHost",
    "contextChoice",
    "signpost",
    "applicationHost",
    "interactions",
  }
  for _, missing in ipairs(required) do
    local partial = baseOptions({})
    partial[missing] = nil
    local ok, err = pcall(FieldSession.new, partial)
    Assert.isFalse(ok, "a session must require " .. missing .. ": " .. tostring(err))
  end
end

-- The session calls required collaborator operations unconditionally on its
-- tick paths, so a collaborator missing one of those methods is the same
-- composition fault as a missing collaborator.
function T.required_collaborator_methods_are_validated_at_construction()
  local cases = {
    { key = "transition", method = "start", label = "transition.start" },
    { key = "dialogue", method = "isModal", label = "dialogue.isModal" },
    { key = "currentMap", method = "updateAnimated", label = "currentMap.updateAnimated" },
    { key = "signpost", method = "isModal", label = "signpost.isModal" },
    { key = "applicationHost", method = "isActive", label = "applicationHost.isActive" },
    { key = "applicationHost", method = "updateFixed", label = "applicationHost.updateFixed" },
    { key = "applicationHost", method = "requestOpen", label = "applicationHost.requestOpen" },
    { key = "applicationHost", method = "takeReopen", label = "applicationHost.takeReopen" },
  }
  for _, case in ipairs(cases) do
    local options = baseOptions({})
    options[case.key][case.method] = nil
    local ok, err = pcall(FieldSession.new, options)
    Assert.isFalse(ok, "a session must require " .. case.label .. ": " .. tostring(err))
  end
end

function T.fixed_ticks_are_render_cadence_independent()
  local a = session()
  a:update(1 / 30)
  local b = session()
  b:update(1 / 60)
  b:update(1 / 60)
  Assert.equal(a.tick, 1)
  Assert.equal(b.tick, 1)
end

function T.excess_backlog_is_discarded_after_max_catch_up()
  local s = session()
  s:update(10 / 30)
  Assert.equal(s.tick, 5)
  -- The 5 excess ticks were dropped, not deferred to the next frame.
  s:update(1 / 30)
  Assert.equal(s.tick, 6)
end

function T.camera_follows_the_player_xyz_each_fixed_tick()
  local s, targets = session()
  s:update(1 / 30)
  Assert.deepEqual(targets[1], { x = 1.25, y = 2.5, z = 3.75 })
end

function T.completed_transition_holds_the_arrival_tile_for_autosave()
  local updates = 0
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      updates = updates + 1
    end,
    collapseRenderInterpolation = function() end,
  }
  local transition = {
    phase = "fade_in",
    locked = true,
    updateFixed = function(self)
      self.phase, self.locked = "idle", false
      self.completed = { destinationMapId = 61 }
    end,
    start = function()
      error("a completing transition never starts a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, updateAnimated = function() end }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
  }))
  s:updateFixed({ heldDirection = "south" })
  Assert.equal(updates, 0)
  Assert.equal(player.fieldZ, 14)
  Assert.notNil(transition.completed)
end

function T.script_completion_consumes_its_final_action_edge()
  local resolved = 0
  local locked = true
  local scheduler = {
    step = function()
      locked = false
    end,
    playerMovementLocked = function()
      return locked
    end,
  }
  local player = {
    fieldX = 0,
    fieldZ = 0,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    motion = "idle",
    updateFixed = function() end,
  }
  local map = { mapId = 61, updateAnimated = function() end } --[[@as any]]
  local camera = { updateFixed = function() end } --[[@as any]]
  local interactions = {
    resolve = function()
      resolved = resolved + 1
    end,
  } --[[@as FieldSession.Interactions]]
  local client = {
    consume = function()
      error("the script client must not be reached while the scheduler owns the tick", 2)
    end,
  }
  local s = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    scriptScheduler = scheduler,
    interactions = interactions,
    scriptClient = client,
  }))
  s:updateFixed({ actionPressed = true })
  Assert.equal(resolved, 0)
end

-- The input snapshot vocabulary is actionPressed/cancelPressed; the
-- scheduler receives edges only through that vocabulary. Snapshot properties
-- outside it are ignored -- the scheduler's own step-input vocabulary
-- (pressedAction/pressedCancel) is a separate contract.
function T.scheduler_edges_come_only_from_current_snapshot_properties()
  local received
  local scheduler = {
    step = function(_, _, snapshot)
      received = snapshot
    end,
    playerMovementLocked = function()
      return false
    end,
  }
  local s = FieldSession.new(baseOptions({ scriptScheduler = scheduler }))
  s:updateFixed({ pressedAction = true, pressedCancel = true })
  Assert.isNil(received.pressedAction, "snapshot pressedAction is not scheduler input")
  Assert.isNil(received.pressedCancel, "snapshot pressedCancel is not scheduler input")
end

-- A modal menu receives normalized UI events through the scheduler input,
-- while its physical edge remains unavailable to field interaction handling.
function T.modal_menu_routes_ui_events_to_the_script_scheduler()
  local input = FieldInput.new()
  local received
  local menuHost = {
    isModal = function()
      return true
    end,
    inputEvents = function(_, events)
      received = events
      return events
    end,
    advance = function() end,
  }
  local scheduler = {
    step = function(_, _, snapshot)
      Assert.equal(snapshot.menuEvents[1].type, "navigate")
      Assert.equal(snapshot.menuEvents[1].direction, "down")
    end,
    playerMovementLocked = function()
      return true
    end,
  }
  local player = {
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    updateFixed = function()
      return false
    end,
  }
  local map = { mapId = 61, updateAnimated = function() end }
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    input = input,
    menuHost = menuHost,
    scriptScheduler = scheduler,
  }))

  input:pressDirection("south", "key:s")
  session:updateFixed()
  Assert.equal(received[1].type, "navigate")
end

function T.the_player_pose_clock_advances_once_per_tick_and_freezes_under_a_transition()
  local steps = 0
  local playerVisual = {
    updateFixed = function()
      steps = steps + 1
    end,
  }
  local player = {
    fieldX = 0,
    fieldZ = 0,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local transition = {
    phase = "idle",
    updateFixed = function() end,
    start = function()
      error("idle transition must never start a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, updateAnimated = function() end }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    playerVisual = playerVisual,
  }))
  s:updateFixed({})
  s:updateFixed({})
  Assert.equal(steps, 2)

  transition.locked = true
  s:updateFixed({})
  Assert.equal(steps, 2, "a locked transition owns the tick, so no pose advances")
end

local function warpSession(options)
  local starts = {}
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function(_, map, trigger, facing)
      starts[#starts + 1] = { map = map, warp = trigger.warp, facing = facing }
    end,
  }
  local warp = { index = 0, x = options.warpX, z = options.warpZ, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp } } },
    updateAnimated = function() end,
    collision = TilePermissions.new(options.tiles),
  }
  local player = {
    fieldX = options.fieldX,
    fieldZ = options.fieldZ,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
  }
  function player:updateFixed()
    if options.commit then
      self.fieldX, self.fieldZ = options.warpX, options.warpZ
      options.commit = false
      return true
    end
    return false
  end
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
  }))
  return session, transition, starts, warp
end

-- The facing-tile door: warp tile (4,14) is a blocked DOOR ahead of the idle
-- player at (4,13) facing south. Behavior bytes come from MetatileBehavior's
-- TILE_BEHAVIOR_* table (pokeheartgold metatile_behavior.h).
local MetatileBehavior = require("libs.engine.src.MetatileBehavior")
local DOOR = MetatileBehavior.BEHAVIOR.DOOR
local ENTRANCE_SOUTH = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_SOUTH
local ENTRANCE_NORTH = MetatileBehavior.BEHAVIOR.WARP_ENTRANCE_NORTH

function T.door_warp_starts_before_player_collision()
  local session, _, starts, warp = warpSession({
    fieldX = 4,
    fieldZ = 13,
    warpX = 4,
    warpZ = 14,
    tiles = { ["4:14"] = { behavior = DOOR, blocked = true } },
  })
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(starts[1].facing, "south")
  Assert.equal(session.player.fieldZ, 13)
end

function T.actor_on_a_blocked_door_cell_does_not_block_the_facing_warp()
  -- A permission-blocked cell with a door warp (the town door pattern)
  -- triggers the warp before a movement start is ever attempted, so occupancy
  -- must not interfere with it.
  local starts = {}
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function(_, map, trigger, facing)
      starts[#starts + 1] = { map = map, warp = trigger.warp, facing = facing }
    end,
  }
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp } } },
    updateAnimated = function() end,
    collision = TilePermissions.new({ ["4:14"] = { behavior = DOOR, blocked = true } }),
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = 4,
    fieldZ = 13,
    surfaceId = 0,
    facing = "south",
    occupancy = function(x, z, surface)
      if x == 4 and z == 14 and surface == 0 then
        return "map:61:object:0"
      end
      return nil
    end,
  })
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
  }))
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(player.fieldZ, 13)
  Assert.equal(player.motion, "idle")
end

function T.actor_on_an_open_warp_cell_blocks_the_walk_but_not_the_route()
  -- A walkable warp cell is entered by stepping in. An actor standing on it
  -- blocks that step -- the original engine's NPC-on-warp-tile behavior --
  -- and the facing path never fires because the tile ahead is walkable
  -- (no door), so no trigger precedes the blocked move.
  local starts = {}
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function(_, map, trigger, facing)
      starts[#starts + 1] = { map = map, warp = trigger.warp, facing = facing }
    end,
  }
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp } } },
    updateAnimated = function() end,
    collision = TilePermissions.new(),
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = 4,
    fieldZ = 13,
    surfaceId = 0,
    facing = "south",
    occupancy = function(x, z, surface)
      if x == 4 and z == 14 and surface == 0 then
        return "map:61:object:0"
      end
      return nil
    end,
  })
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
  }))
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(#starts, 0)
  Assert.equal(player.fieldZ, 13)
  Assert.equal(player.motion, "idle")
end

function T.standing_generic_warp_starts_when_a_step_commits()
  -- A step onto a north-entrance tile (the step-path generic kind) starts
  -- immediately on the committing tick, matching FieldSystem_CheckTransition.
  local session, _, starts, warp = warpSession({
    fieldX = 4,
    fieldZ = 13,
    warpX = 4,
    warpZ = 14,
    commit = true,
    tiles = { ["4:14"] = { behavior = ENTRANCE_NORTH } },
  })
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(session.player.fieldZ, 14)
end

function T.entrance_south_warp_starts_on_the_facing_path_after_the_step()
  -- The Elm Lab door pattern: stepping onto the walkable WARP_ENTRANCE_SOUTH
  -- tile starts nothing (step path is generic-only); the trigger fires the
  -- next tick through the facing path, while the idle player holds south
  -- toward the blocked wall tile ahead.
  local session, _, starts, warp = warpSession({
    fieldX = 4,
    fieldZ = 13,
    warpX = 4,
    warpZ = 14,
    commit = true,
    tiles = {
      ["4:14"] = { behavior = ENTRANCE_SOUTH },
      ["4:15"] = { blocked = true },
    },
  })
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(#starts, 0, "the step path must not fire a direction-gated warp")
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(starts[1].facing, "south")
end

function T.entrance_south_warp_does_not_start_without_its_facing_direction()
  local session, _, starts = warpSession({
    fieldX = 4,
    fieldZ = 14,
    warpX = 4,
    warpZ = 14,
    tiles = {
      ["4:14"] = { behavior = ENTRANCE_SOUTH },
      ["4:15"] = { blocked = true },
    },
  })
  session:updateFixed({ heldDirection = "north" })
  Assert.equal(#starts, 0)
end

function T.arrival_suppression_prevents_immediate_standing_bounce()
  local session, transition, starts = warpSession({
    fieldX = 4,
    fieldZ = 14,
    warpX = 4,
    warpZ = 14,
    commit = true,
    tiles = { ["4:14"] = { behavior = ENTRANCE_NORTH } },
  })
  transition.suppression = { mapId = 61, fieldX = 4, fieldZ = 14 }
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(#starts, 0)
  Assert.notNil(transition.suppression)
  session.player.fieldZ = 15
  session:updateFixed({})
  Assert.isNil(transition.suppression)
end

local function dialogueSession(opts)
  opts = opts or {}
  local worldSteps = { player = 0, actors = 0, camera = 0, visual = 0 }
  local dialogueSteps = 0
  local received
  local dialogue = {
    modal = opts.modal ~= false,
    isModal = function(self)
      return self.modal
    end,
    step = function(self, snapshot)
      dialogueSteps = dialogueSteps + 1
      received = snapshot
    end,
  }
  local player = {
    fieldX = 4,
    fieldZ = 13,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      worldSteps.player = worldSteps.player + 1
      return false
    end,
  }
  local camera = {
    updateFixed = function()
      worldSteps.camera = worldSteps.camera + 1
    end,
  }
  local actors = {
    step = function()
      worldSteps.actors = worldSteps.actors + 1
    end,
  }
  local playerVisual = {
    updateFixed = function()
      worldSteps.visual = worldSteps.visual + 1
    end,
  }
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("dialogue fixture never starts a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, fieldData = { events = { warps = {} } }, updateAnimated = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    actors = actors,
    playerVisual = playerVisual,
    dialogue = dialogue,
  }))
  return session, worldSteps, function()
    return dialogueSteps, received
  end, dialogue
end

function T.modal_dialogue_freezes_every_world_step_and_steps_the_dialogue()
  local session, worldSteps, dialogueState = dialogueSession()
  session:updateFixed({ heldDirection = "south", actionDown = true })
  Assert.equal(worldSteps.player, 0, "player does not move")
  Assert.equal(worldSteps.actors, 0, "visibility changes do not apply")
  Assert.equal(worldSteps.camera, 0, "camera holds its target")
  Assert.equal(worldSteps.visual, 0, "pose clocks pause")
  local steps, received = dialogueState()
  Assert.equal(steps, 1)
  Assert.equal(received.actionDown, true)
  Assert.equal(received.heldDirection, "south")
end

function T.modal_dialogue_blocks_warp_evaluation()
  local session, _, _ = dialogueSession()
  local map = { mapId = 61, fieldData = { events = { warps = {} } }, updateAnimated = function() end }
  session.currentMap = map
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(session.player.fieldZ, 13, "no movement and no warp from the modal tick")
end

function T.world_resumes_once_the_dialogue_closes()
  local session, worldSteps, dialogueState, dialogue = dialogueSession()
  session:updateFixed({})
  Assert.equal(worldSteps.player, 0)
  -- The dialogue closes (its own step dispatches the completion); the next
  -- session tick runs the world again.
  dialogue.modal = false
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(worldSteps.player, 1)
  Assert.equal(worldSteps.camera, 1)
end

function T.transition_commit_clears_stale_action_edges()
  local input = FieldInput.new()
  input:pressAction("key:space")
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local transition = {
    phase = "fade_in",
    locked = true,
    updateFixed = function(self)
      self.phase, self.locked = "idle", false
      self.completed = { destinationMapId = 60 }
    end,
    start = function()
      error("a completing transition never starts a warp", 2)
    end,
  }
  local camera = { updateFixed = function() end }
  local map = { mapId = 61, cameraType = 4, updateAnimated = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    input = input,
  }))
  session:updateFixed({ actionPressed = true })
  -- The commit tick consumed the snapshot edge and cleared the input object's
  -- pending edges, so a later tick cannot act on a stale action edge after
  -- the fade; held state legitimately survives.
  Assert.isFalse(input.actionPressed, "no stale pressed edge survives the commit")
  Assert.equal(input.actionDown, true, "held state survives the commit")
end

local function interactionSession(opts)
  opts = opts or {}
  local resolved, consumed
  local interactions
  interactions = {
    resolve = function(_, snapshot)
      resolved = snapshot
      interactions.resolveSnapshot = snapshot
      return opts.intent or nil
    end,
  }
  local client = {
    consume = function(_, intent, tick)
      consumed = intent
      interactions.consumedIntent = intent
      return opts.result or ScriptInteractionClient.RESULTS.started
    end,
  }
  local steps = 0
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "north",
    motion = "idle",
    updateFixed = function()
      steps = steps + 1
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local camera = { updateFixed = function() end }
  local actors = { step = function() end }
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("interaction fixture never starts a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, fieldData = { events = { warps = {} } }, updateAnimated = function() end }
  local dialogue = {
    isModal = function()
      return opts.modalDialogue == true
    end,
    step = function() end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    actors = actors,
    interactions = interactions,
    scriptClient = client,
    dialogue = dialogue,
  }))
  return session, player, interactions, function()
    return steps
  end
end

function T.consumed_interaction_owns_the_tick()
  local session, player, interactions, steps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session:updateFixed({ actionPressed = true, heldDirection = "north" })
  assert(interactions.resolveSnapshot, "the resolver must have been consulted")
  assert(interactions.consumedIntent, "the resolved intent must be dispatched")
  Assert.equal(steps(), 0, "a consumed interaction blocks movement on the same tick")
  Assert.equal(player.facing, "north", "the held direction did not start a step")
  Assert.equal(session.tick, 1)
end

function T.unresolved_interaction_falls_through_to_movement()
  local session, player, interactions, steps = interactionSession()
  session:updateFixed({ actionPressed = true, heldDirection = "north" })
  Assert.equal(steps(), 1, "a nil intent leaves the tick to movement")
  Assert.equal(player.facing, "north")
end

-- The binding audit guarantees every interactable event is bound; an
-- unmapped intent reaching the session is a composition fault that must fail
-- loudly, never a silently absorbed Action press.
function T.unmapped_interaction_is_a_composition_fault()
  local session, player, interactions, steps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
    result = ScriptInteractionClient.RESULTS.unmapped,
  })
  Assert.throws(function()
    session:updateFixed({ actionPressed = true, heldDirection = "north" })
  end)
  Assert.equal(steps(), 0, "a faulting interaction must not start movement")
end

-- A foreground script already owning the field blocks the new interaction;
-- the tick is still consumed.
function T.blocked_interaction_still_consumes_the_tick()
  local session, player, interactions, steps = interactionSession({
    intent = { kind = "background" },
    result = ScriptInteractionClient.RESULTS.blocked,
  })
  session:updateFixed({ actionPressed = true, heldDirection = "north" })
  Assert.equal(steps(), 0, "a blocked interaction consumes the tick")
  Assert.equal(player.facing, "north")
end

function T.interaction_resolve_snapshot_carries_the_player_state()
  local session, player, interactions = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session:updateFixed({ actionPressed = true })
  local snapshot = interactions.resolveSnapshot
  assert(snapshot, "the resolver must have been consulted")
  Assert.equal(snapshot.runtimeMap.mapId, 61)
  Assert.equal(snapshot.fieldX, 4)
  Assert.equal(snapshot.fieldZ, 14)
  Assert.equal(snapshot.facing, "north")
  Assert.equal(snapshot.tick, 1)
end

function T.interaction_never_resolves_while_walking()
  local session, player, interactions = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  player.motion = "walking"
  session:updateFixed({ actionPressed = true })
  Assert.isNil(interactions.resolveSnapshot, "a moving player is never asked to interact")
end

function T.interaction_never_resolves_without_the_action_edge()
  local session, player, interactions = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session:updateFixed({ actionDown = true, heldDirection = "north" })
  Assert.isNil(interactions.resolveSnapshot, "held Action alone never resolves")
end

function T.interaction_never_resolves_under_a_locked_transition_or_modal()
  local session, _, interactions, steps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session.transition.locked = true
  session:updateFixed({ actionPressed = true })
  Assert.isNil(interactions.resolveSnapshot, "a locked transition owns the tick")
  Assert.equal(steps(), 0)

  local modalSession, _, modalInteractions, modalSteps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
    modalDialogue = true,
  })
  modalSession:updateFixed({ actionPressed = true })
  Assert.isNil(modalInteractions.resolveSnapshot, "modal ownership blocks new interactions")
  Assert.equal(modalSteps(), 0)
end

function T.catch_up_ticks_do_not_replay_one_action_edge()
  local input = FieldInput.new()
  input:pressAction("key:space")
  local resolved = 0
  local interactions = {
    resolve = function()
      resolved = resolved + 1
      return { kind = "object", object = { actorId = "map:61:object:0" } }
    end,
  }
  local client = {
    consume = function()
      return ScriptInteractionClient.RESULTS.started
    end,
  }
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "north",
    motion = "idle",
    updateFixed = function()
      return false
    end,
  }
  local camera = { updateFixed = function() end }
  local actors = { step = function() end }
  local transition = {
    phase = "idle",
    locked = false,
    updateFixed = function() end,
    start = function()
      error("catch-up fixture never starts a warp", 2)
    end,
  }
  local map = { mapId = 61, cameraType = 4, updateAnimated = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    actors = actors,
    input = input,
    interactions = interactions,
    scriptClient = client,
  }))
  -- A render delta spanning several fixed ticks: the one Action edge must be
  -- consumed by the first tick's snapshot and never replayed by catch-up.
  -- update() takes no snapshot of its own -- each fixed step samples the input,
  -- so even a stale snapshot passed along must be ignored.
  ---@diagnostic disable-next-line: redundant-parameter -- intentional: a stale snapshot must never be replayed
  session:update(5 * FieldSession.FIXED_DT, { actionPressed = true })
  Assert.equal(session.tick, 5, "the full catch-up ran")
  Assert.equal(resolved, 1, "one Action edge must not be replayed over catch-up ticks")
  Assert.isFalse(input.actionPressed, "the first tick consumed the edge")
  Assert.equal(input.actionDown, true, "held state survives the edge")
end

-- renderAlpha is an interpolation factor the renderer forwards to the
-- camera; extreme render deltas must not push it out of [0, 1]. A huge delta
-- saturates the catch-up cap and drops the remainder, and a near-boundary
-- delta leaves a negative float residual in the drop branch, so the clamp is
-- a real invariant, not a formality.
function T.render_alpha_stays_in_unit_range_after_extreme_deltas()
  local session, _, _, _ = warpSession({
    fieldX = 4,
    fieldZ = 14,
    warpX = 4,
    warpZ = 14,
  })
  local function assertInRange(label)
    local alpha = session:renderAlpha()
    Assert.isTrue(alpha >= 0 and alpha <= 1, label .. " renderAlpha out of [0, 1]: " .. tostring(alpha))
  end
  -- A near-boundary delta leaves a negative float residual in the drop
  -- branch, so the clamp is a real invariant, not a formality.
  session:update(1.8)
  assertInRange("drop")
  -- A huge delta saturates the catch-up cap and drops the remainder.
  session:update(600)
  assertInRange("catch-up")
end

-- The session captures the player's walking state before the movement update
-- and hands it to the pose clock, so a two-tile walk (16 ticks, the ROM's full
-- gait range) keeps one continuous phase instead of restarting at each commit.
function T.a_two_tile_walk_keeps_one_phase_across_the_session_ticks()
  local map = {
    mapId = 61,
    cameraType = 4,
    coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = {} } },
    updateAnimated = function() end,
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
  local player = FieldPlayer.new({
    currentMap = map,
    fieldX = 4,
    fieldZ = 13,
    surfaceId = 0,
    facing = "south",
    occupancy = function()
      return nil
    end,
  })
  local visual = FieldPlayerVisual.new({
    player = player,
    spriteId = 0,
  })
  local camera = { updateFixed = function() end }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    playerVisual = visual,
  }))

  session:updateFixed({ heldDirection = "east", pressedDirection = "east" })
  for tick = 2, 16 do
    session:updateFixed({ heldDirection = "east" })
  end

  Assert.equal(player.fieldX, 6, "two eight-tick steps committed")
  Assert.equal(player.motion, "idle")
  Assert.equal(visual.pose, "walk")
  Assert.equal(visual.poseTick, 16, "the session never lets the gait phase restart mid-walk")
end

-- A locked door transition reports whether the choreography moved the player
-- this tick; the session then advances the pose clock (only on moved ticks),
-- the camera (every locked tick, so interpolation pairs never replay), and
-- the scene's animated props -- the door opening/closing -- while everything
-- else stays frozen.
function T.door_transition_ticks_advance_the_world_while_locked()
  local visualSteps, cameraSteps, animatedSteps = 0, 0, 0
  local transition = {
    phase = "fade_out",
    locked = true,
    moved = false,
    updateFixed = function(self)
      return self.moved
    end,
    start = function() end,
  }
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "walking",
    updateFixed = function()
      return false
    end,
  }
  local camera = {
    updateFixed = function()
      cameraSteps = cameraSteps + 1
    end,
  }
  local playerVisual = {
    updateFixed = function(_, walking)
      Assert.isTrue(walking, "the pose clock hears the mid-step tick")
      visualSteps = visualSteps + 1
    end,
  }
  local map = {
    mapId = 61,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        animatedSteps = animatedSteps + 1
      end,
    },
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
    end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    playerVisual = playerVisual,
  }))

  transition.moved = true
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(visualSteps, 1, "the walk pose advances during the choreography")
  Assert.equal(cameraSteps, 1, "the camera follows the ingress/egress")
  Assert.equal(animatedSteps, 1, "the door animation advances under the locked transition")

  transition.moved = false
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(visualSteps, 1, "a standing door tick does not advance the pose clock")
  Assert.equal(cameraSteps, 2, "the camera still samples the standing player (no replayed interpolation)")
  Assert.equal(animatedSteps, 2, "the door open/close keeps advancing while the player stands")
end

-- A locked stair transition advances the scene's animated props and samples
-- the camera each tick but never reports locomotion: the climb is in place,
-- so the pose clock stays frozen while the props keep animating.
function T.stair_transition_ticks_advance_props_but_not_the_pose_clock()
  local visualSteps, cameraSteps, animatedSteps = 0, 0, 0
  local transition = {
    phase = "fade_out",
    locked = true,
    updateFixed = function()
      return false
    end,
    start = function() end,
  }
  local player = {
    fieldX = 3,
    fieldZ = 3,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "west",
    motion = "idle",
    updateFixed = function()
      return false
    end,
    collapseRenderInterpolation = function() end,
  }
  local camera = {
    updateFixed = function()
      cameraSteps = cameraSteps + 1
    end,
  }
  local playerVisual = {
    updateFixed = function()
      visualSteps = visualSteps + 1
    end,
  }
  local map = {
    mapId = 63,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        animatedSteps = animatedSteps + 1
      end,
    },
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
    end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    playerVisual = playerVisual,
  }))

  session:updateFixed({ heldDirection = "west" })
  Assert.equal(animatedSteps, 1, "the scene props advance under the stair climb")
  Assert.equal(visualSteps, 0, "the in-place climb does not advance the pose clock")
  Assert.equal(cameraSteps, 1, "the camera samples the standing player (zero delta)")
  session:updateFixed({ heldDirection = "west" })
  Assert.equal(animatedSteps, 2, "the props keep advancing while the player stands")
  Assert.equal(cameraSteps, 2)
end

-- A plain locked transition advances the scene's animated props and samples
-- the camera, but never the pose clock: the scene clock runs on every locked
-- tick, while locomotion-driven state stays frozen.
function T.plain_locked_transition_stays_frozen()
  local visualSteps, cameraSteps, animatedSteps = 0, 0, 0
  local transition = {
    phase = "fade_out",
    locked = true,
    updateFixed = function()
      return false
    end,
    start = function() end,
  }
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "walking",
    updateFixed = function()
      return false
    end,
  }
  local camera = {
    updateFixed = function()
      cameraSteps = cameraSteps + 1
    end,
  }
  local playerVisual = {
    updateFixed = function()
      visualSteps = visualSteps + 1
    end,
  }
  local map = {
    mapId = 61,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        animatedSteps = animatedSteps + 1
      end,
    },
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
    end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    transition = transition,
    playerVisual = playerVisual,
  }))
  session:updateFixed({})
  Assert.equal(visualSteps, 0, "no locomotion: the pose clock stays frozen")
  Assert.equal(cameraSteps, 1, "the camera still samples every locked tick")
  Assert.equal(animatedSteps, 1, "the scene clock advances on every locked tick")
end

-- The visual shake regression: during choreo_hold there is no player step, so
-- both the camera and player sprite must collapse stale interpolation pairs.
-- Otherwise every render interval replays the final fraction of the egress
-- step while the door animation runs. This is most visible as vertical shake
-- for north/south doors, whose Z movement projects vertically on screen.
function T.choreo_hold_ticks_never_replay_camera_or_player_interpolation()
  local FieldCamera = require("libs.engine.src.FieldCamera")
  local profile = {
    projectionType = "orthographic",
    distanceTiles = 10,
    angleXRaw = 0,
    angleYRaw = 0,
    halfFovRadians = math.rad(45),
    fullVerticalFovRadians = math.rad(45),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  }
  local function matrixEquals(a, b)
    for i = 1, 16 do
      if math.abs(a[i] - b[i]) > 1e-9 then
        return false
      end
    end
    return true
  end

  local function pointEquals(a, b)
    return math.abs(a.x - b.x) <= 1e-9 and math.abs(a.y - b.y) <= 1e-9 and math.abs(a.z - b.z) <= 1e-9
  end

  local function runDoorClose(withVisual)
    local camera = FieldCamera.new(profile, { initialTarget = { x = 0, y = 0, z = 0 } })
    local map = {
      mapId = 61,
      cameraType = 4,
      coordinateOrigin = { x = 0, z = 0 },
      updateAnimated = function() end,
      collision = TilePermissions.new(),
      terrain = TerrainSurface.new({
        plates = {
          {
            id = 0,
            minX = 0,
            minZ = 0,
            maxX = 32,
            maxZ = 32,
            normal = { x = 0, y = 1, z = 0 },
            distance = 0,
            slopeClass = "flat",
          },
        },
      }),
    }
    local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 14, surfaceId = 0, facing = "south" })
    Assert.isTrue(player:scriptedStep("south"))
    for _ = 1, FieldPlayer.WALK_STEP_TICKS do
      player:updateFixed({})
    end
    Assert.isFalse(
      pointEquals(player:renderPosition(0), player:renderPosition(1)),
      "the completed egress leaves one real interpolation pair"
    )
    local playerVisual = withVisual and {
      updateFixed = function() end,
    } or nil
    local transition = {
      phase = "choreo_hold",
      locked = true,
      updateFixed = function()
        return false
      end,
      start = function() end,
    }
    local session = FieldSession.new(baseOptions({
      currentMap = map,
      player = player,
      camera = camera,
      transition = transition,
      playerVisual = playerVisual,
    }))
    -- Prime the interpolation pair with a real movement.
    camera:updateFixed({ x = 2, y = 0, z = 2 })
    Assert.isFalse(matrixEquals(camera:view(0), camera:view(1)), "the primed pair differs")
    -- The first stationary door-close tick collapses the player's final step;
    -- the second also collapses the camera pair after its last real target.
    session:updateFixed({})
    Assert.isTrue(
      pointEquals(player:renderPosition(0), player:renderPosition(1)),
      "the first door-close tick settles player interpolation"
    )
    session:updateFixed({})
    Assert.isTrue(matrixEquals(camera:view(0), camera:view(1)), "no replayed interpolation while the door closes")
    -- The completion tick also samples before the session consumes it.
    transition.completed = { destinationMapId = 60 }
    session:updateFixed({})
    Assert.isTrue(matrixEquals(camera:view(0), camera:view(1)), "the completion tick samples the camera too")
  end

  runDoorClose(true)
  runDoorClose(false)
end

-- The scene animation clock also runs on script-locked ticks: a script that
-- takes movement ownership freezes the player but not the world's props.
function T.script_locked_ticks_still_advance_the_scene_clock()
  local animatedSteps = 0
  local player = {
    fieldX = 4,
    fieldZ = 14,
    worldX = 0,
    worldY = 0,
    worldZ = 0,
    surfaceId = 0,
    facing = "south",
    motion = "idle",
    updateFixed = function()
      return false
    end,
  }
  local camera = { updateFixed = function() end }
  local map = {
    mapId = 61,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        animatedSteps = animatedSteps + 1
      end,
    },
    updateAnimated = function(self)
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
    end,
  }
  local scheduler = {
    step = function() end,
    playerMovementLocked = function()
      return true
    end,
  }
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    camera = camera,
    scriptScheduler = scheduler,
  }))
  session:updateFixed({})
  Assert.equal(animatedSteps, 1, "a script-locked tick advances the scene clock once")
  Assert.equal(session.tick, 1)
end

-- The field clock contract: FieldSession steps one aggregate map entry point
-- per fixed tick; FieldMapLoader owns the fan-out to the central scene
-- runtime and the neighbor coverage runtime. This fake mirrors that
-- aggregate so a branch can only pass by going through the map clock.
local function clockMap()
  local calls = { aggregate = 0, scene = 0, coverage = 0 }
  local map = {
    mapId = 61,
    cameraType = 4,
    sceneRuntime = {
      updateAnimated = function()
        calls.scene = calls.scene + 1
      end,
    },
    coverageRuntime = {
      updateAnimated = function()
        calls.coverage = calls.coverage + 1
      end,
    },
    updateAnimated = function(self)
      calls.aggregate = calls.aggregate + 1
      if self.sceneRuntime then
        self.sceneRuntime:updateAnimated()
      end
      if self.coverageRuntime then
        self.coverageRuntime:updateAnimated()
      end
    end,
  }
  return map, calls
end

-- An ordinary tick advances the central scene runtime and the neighbor
-- coverage runtime exactly once each, through the aggregate map clock.
function T.normal_ticks_advance_scene_and_coverage_once_through_the_map_clock()
  local map, calls = clockMap()
  local session = FieldSession.new(baseOptions({ currentMap = map }))
  session:updateFixed({})
  Assert.equal(calls.aggregate, 1, "the normal tick advances the aggregate map clock exactly once")
  Assert.equal(calls.scene, 1, "the central scene runtime advances exactly once")
  Assert.equal(calls.coverage, 1, "the coverage runtime advances exactly once")
  session:updateFixed({})
  Assert.equal(calls.aggregate, 2, "each normal tick advances the aggregate map clock exactly once")
  Assert.equal(calls.scene, 2, "each normal tick advances the scene runtime exactly once")
  Assert.equal(calls.coverage, 2, "each normal tick advances the coverage runtime exactly once")
end

-- A locked transition tick advances both runtimes exactly once through the
-- aggregate map clock, alongside the camera sampling and pose freezing.
function T.locked_transition_ticks_advance_scene_and_coverage_once_through_the_map_clock()
  local player = defaultPlayer()
  player.collapseRenderInterpolation = function() end
  local transition = {
    phase = "fade_out",
    locked = true,
    updateFixed = function()
      return false
    end,
    start = function() end,
  }
  local map, calls = clockMap()
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    player = player,
    transition = transition,
  }))
  session:updateFixed({})
  Assert.equal(calls.aggregate, 1, "the locked transition tick advances the aggregate map clock exactly once")
  Assert.equal(calls.scene, 1, "the central scene runtime advances exactly once")
  Assert.equal(calls.coverage, 1, "the coverage runtime advances exactly once")
end

-- A modal-dialogue tick owns the field while the world steps freeze, but the
-- scene clock keeps running: both runtimes advance exactly once through the
-- aggregate map clock.
function T.modal_dialogue_ticks_advance_scene_and_coverage_once_through_the_map_clock()
  local dialogue = {
    isModal = function()
      return true
    end,
    step = function() end,
  }
  local map, calls = clockMap()
  local session = FieldSession.new(baseOptions({
    currentMap = map,
    dialogue = dialogue,
  }))
  session:updateFixed({})
  Assert.equal(calls.aggregate, 1, "the modal-dialogue tick advances the aggregate map clock exactly once")
  Assert.equal(calls.scene, 1, "the central scene runtime advances exactly once")
  Assert.equal(calls.coverage, 1, "the coverage runtime advances exactly once")
end

-- The application host is the one application modal owner: while it is
-- active, the session steps only the host (once per fixed tick, with the
-- tick's UI event list plus the synthesized menu edge) and freezes world
-- simulation -- no player step, no actor step, no scheduler step, no
-- interaction, no movement.
function T.application_host_owns_the_tick_and_freezes_world_simulation()
  local stepped = { player = 0, actors = 0, scheduler = 0, map = 0 }
  local player = defaultPlayer()
  player.updateFixed = function()
    stepped.player = stepped.player + 1
    return false
  end
  local actors = {
    step = function()
      stepped.actors = stepped.actors + 1
    end,
  }
  local scheduler = {
    step = function()
      stepped.scheduler = stepped.scheduler + 1
    end,
    playerMovementLocked = function()
      return false
    end,
  }
  local map = {
    mapId = 61,
    fieldData = { events = { warps = {} } },
    updateAnimated = function()
      stepped.map = stepped.map + 1
    end,
  }
  local host = applicationHostFake({ active = true })
  local input = idleInput()
  input.uiSnapshot = function()
    return { { type = "navigate", direction = "down" } }
  end
  local session = FieldSession.new(baseOptions({
    player = player,
    actors = actors,
    scriptScheduler = scheduler,
    currentMap = map,
    applicationHost = host,
    input = input,
  }))
  session:updateFixed({ menuPressed = true })
  Assert.equal(host.updateCalls, 1, "the host is stepped exactly once per tick")
  Assert.equal(host.events[1].type, "navigate", "the host receives the tick's UI events")
  Assert.equal(host.events[2].type, "menu", "a menu edge while active closes through the synthesized menu event")
  Assert.equal(stepped.player, 0, "the player is not stepped while the host owns the tick")
  Assert.equal(stepped.actors, 0, "actors are not stepped while the host owns the tick")
  Assert.equal(stepped.scheduler, 0, "the script scheduler is not stepped while the host owns the tick")
  Assert.equal(stepped.map, 0, "the scene animation clock is frozen while the host owns the tick")
  Assert.equal(session.tick, 1)
end

function T.while_the_host_is_active_no_other_modal_may_own_the_tick()
  local dialogue = {
    isModal = function()
      return true
    end,
  }
  local host = applicationHostFake({ active = true })
  local session = FieldSession.new(baseOptions({
    dialogue = dialogue,
    applicationHost = host,
  }))
  Assert.throws(function()
    session:updateFixed({})
  end)
end

-- The menu edge is checked after the script-scheduler step and before
-- actor stepping/interaction/warps/movement; an eligible open consumes the
-- tick so the same edge cannot also start a move or interaction.
function T.an_eligible_menu_edge_opens_the_menu_and_consumes_the_tick()
  local stepped = { player = 0, actors = 0 }
  local player = defaultPlayer()
  player.updateFixed = function()
    stepped.player = stepped.player + 1
    return false
  end
  local actors = {
    step = function()
      stepped.actors = stepped.actors + 1
    end,
  }
  local host = applicationHostFake()
  local session = FieldSession.new(baseOptions({
    player = player,
    actors = actors,
    applicationHost = host,
  }))
  session:updateFixed({ menuPressed = true })
  Assert.equal(host.openedTicks[1], 1, "the eligible menu edge opens the menu at the session tick")
  Assert.equal(stepped.player, 0, "a successful open consumes the tick")
  Assert.equal(stepped.actors, 0, "a successful open consumes the tick before actor stepping")
  Assert.equal(session.tick, 1)
end

function T.menu_wins_over_a_simultaneous_action_edge_at_an_eligible_boundary()
  local interactions = 0
  local host = applicationHostFake()
  local session = FieldSession.new(baseOptions({
    applicationHost = host,
    interactions = {
      resolve = function()
        interactions = interactions + 1
        return {}
      end,
    },
  }))
  session:updateFixed({ menuPressed = true, actionPressed = true })
  Assert.equal(host.openedTicks[1], 1, "the menu edge wins at an eligible boundary")
  Assert.equal(interactions, 0, "the cleared Action edge must not trigger the facing interaction")
end

function T.an_ineligible_menu_edge_acquires_nothing()
  local host = applicationHostFake()
  local player = defaultPlayer()
  player.motion = "walking"
  local session = FieldSession.new(baseOptions({
    player = player,
    applicationHost = host,
  }))
  session:updateFixed({ menuPressed = true })
  Assert.equal(host.openedTicks[1], nil, "an ineligible open edge must not open the menu")
  Assert.equal(session.tick, 1, "the tick still advances normally")
end

function T.a_movement_lock_blocks_the_menu_edge()
  local host = applicationHostFake()
  local scheduler = {
    step = function() end,
    playerMovementLocked = function()
      return true
    end,
  }
  local session = FieldSession.new(baseOptions({
    applicationHost = host,
    scriptScheduler = scheduler,
  }))
  session:updateFixed({ menuPressed = true })
  Assert.equal(host.openedTicks[1], nil, "a foreground script lock must block the open")
end

-- The script-side reopen request (opcode 61) is consumed at the same
-- arbitration point, unconditionally: a pending reopen opens the menu and
-- consumes the tick.
function T.a_pending_reopen_opens_the_menu_at_the_arbitration_point()
  local stepped = { player = 0 }
  local player = defaultPlayer()
  player.updateFixed = function()
    stepped.player = stepped.player + 1
    return false
  end
  local host = applicationHostFake()
  host:requestReopen()
  local session = FieldSession.new(baseOptions({
    player = player,
    applicationHost = host,
  }))
  session:updateFixed({})
  Assert.equal(host.openedTicks[1], 1, "the pending reopen opens the menu")
  Assert.equal(host.reopenRequests, 0, "the reopen request is consumed once")
  Assert.equal(stepped.player, 0, "the reopen open consumes the tick")
end

return { tests = T }
