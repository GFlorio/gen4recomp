-- Fixed-step session tests prove deterministic tick counts, catch-up capping,
-- and that the camera consumes the placeholder actor's continuous 3D target.

local Assert = require("tests.support.Assert")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldPlayerVisual = require("libs.engine.src.FieldPlayerVisual")
local FieldSession = require("libs.engine.src.FieldSession")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function session()
  local targets = {}
  local camera = { updateFixed = function(_, target)
    targets[#targets + 1] = { x = target.x, y = target.y, z = target.z }
  end }
  local actor = { worldX = 1.25, worldY = 2.5, worldZ = 3.75 }
  local map = { mapId = 61 }
  return FieldSession.new({ versionId = "heartgold", currentMap = map,
    actor = actor, camera = camera }), targets
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

function T.camera_follows_the_actor_xyz_each_fixed_tick()
  local s, targets = session()
  s:update(1 / 30)
  Assert.deepEqual(targets[1], { x = 1.25, y = 2.5, z = 3.75 })
end

function T.completed_transition_holds_the_arrival_tile_for_autosave()
  local updates = 0
  local actor = {
    fieldX = 4, fieldZ = 14, worldX = 0, worldY = 0, worldZ = 0,
    surfaceId = 0, facing = "south", motion = "idle",
    updateFixed = function() updates = updates + 1 end,
  }
  local transition = {
    phase = "fade_in", locked = true,
    updateFixed = function(self)
      self.phase, self.locked = "idle", false
      self.completed = { destinationMapId = 61 }
    end,
  }
  local map = { mapId = 61, cameraType = 4 }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new({
    versionId = "heartgold", currentMap = map,
    actor = actor, player = actor, camera = camera,
    transition = transition,
  })
  s:updateFixed({ heldDirection = "south" })
  Assert.equal(updates, 0)
  Assert.equal(actor.fieldZ, 14)
  Assert.notNil(transition.completed)
end

function T.the_player_pose_clock_advances_once_per_tick_and_freezes_under_a_transition()
  local steps = 0
  local playerVisual = { updateFixed = function() steps = steps + 1 end }
  local actor = {
    fieldX = 0, fieldZ = 0, worldX = 0, worldY = 0, worldZ = 0,
    surfaceId = 0, facing = "south", motion = "idle",
    updateFixed = function() return false end,
  }
  local transition = { phase = "idle", updateFixed = function() end }
  local map = { mapId = 61, cameraType = 4 }
  local camera = { updateFixed = function() end }
  local s = FieldSession.new({
    versionId = "heartgold", currentMap = map,
    actor = actor, player = actor, camera = camera,
    transition = transition, playerVisual = playerVisual,
  })
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
    phase = "idle", locked = false,
    updateFixed = function() end,
    start = function(_, map, warp, facing)
      starts[#starts + 1] = { map = map, warp = warp, facing = facing }
    end,
  }
  local warp = { index = 0, x = options.warpX, z = options.warpZ,
    destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = {
    mapId = 61, cameraType = 4, coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp } } },
    permissions = {
      containsLocal = function(_, x, z) return x >= 0 and x < 32 and z >= 0 and z < 32 end,
      isBlockedLocal = function(_, x, z) return options.blocked == x .. ":" .. z end,
    },
  }
  local actor = {
    fieldX = options.fieldX, fieldZ = options.fieldZ,
    worldX = 0, worldY = 0, worldZ = 0, surfaceId = 0,
    facing = "south", motion = "idle",
  }
  function actor:updateFixed()
    if options.commit then
      self.fieldX, self.fieldZ = options.warpX, options.warpZ
      options.commit = false
      return true
    end
    return false
  end
  local camera = { updateFixed = function() end }
  local session = FieldSession.new({ versionId = "heartgold", currentMap = map,
    actor = actor, player = actor, camera = camera, transition = transition })
  return session, transition, starts, warp
end

function T.blocked_facing_warp_starts_before_player_collision()
  local session, _, starts, warp = warpSession({
    fieldX = 4, fieldZ = 13, warpX = 4, warpZ = 14, blocked = "4:14",
  })
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(starts[1].facing, "south")
  Assert.equal(session.player.fieldZ, 13)
end

function T.actor_on_a_blocked_warp_cell_does_not_block_the_facing_warp()
  -- A permission-blocked cell with a warp (the lab exit pattern) triggers the
  -- warp before a movement start is ever attempted, so occupancy must not
  -- interfere with it.
  local starts = {}
  local transition = {
    phase = "idle", locked = false,
    updateFixed = function() end,
    start = function(_, map, warp, facing)
      starts[#starts + 1] = { map = map, warp = warp, facing = facing }
    end,
  }
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = {
    mapId = 61, cameraType = 4, coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp } } },
    permissions = {
      containsLocal = function(_, x, z) return x >= 0 and x < 32 and z >= 0 and z < 32 end,
      isBlockedLocal = function(_, x, z) return x == 4 and z == 14 end,
    },
    terrain = TerrainSurface.new({ plates = {
      { id = 0, minX = 0, minZ = 0, maxX = 32, maxZ = 32,
        normal = { x = 0, y = 1, z = 0 }, distance = 0, slopeClass = "flat" },
    } }),
  }
  local player = FieldPlayer.new({
    currentMap = map, fieldX = 4, fieldZ = 13, surfaceId = 0, facing = "south",
    occupancy = function(x, z, surface)
      if x == 4 and z == 14 and surface == 0 then return "map:61:object:0" end
      return nil
    end,
  })
  local camera = { updateFixed = function() end }
  local session = FieldSession.new({ versionId = "heartgold", currentMap = map,
    actor = player, player = player, camera = camera, transition = transition })
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(player.fieldZ, 13)
  Assert.equal(player.motion, "idle")
end

function T.actor_on_an_open_warp_cell_blocks_the_walk_but_not_the_route()
  -- A walkable warp cell is entered by stepping in. An actor standing on it
  -- blocks that step -- the original engine's NPC-on-warp-tile behavior -- and
  -- the standing-warp check never fires because the move never commits.
  local starts = {}
  local transition = {
    phase = "idle", locked = false,
    updateFixed = function() end,
    start = function(_, map, warp, facing)
      starts[#starts + 1] = { map = map, warp = warp, facing = facing }
    end,
  }
  local warp = { index = 0, x = 4, z = 14, destinationMapId = 60, destinationWarpId = 0, y = 0 }
  local map = {
    mapId = 61, cameraType = 4, coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = { warp } } },
    permissions = {
      containsLocal = function(_, x, z) return x >= 0 and x < 32 and z >= 0 and z < 32 end,
      isBlockedLocal = function() return false end,
    },
    terrain = TerrainSurface.new({ plates = {
      { id = 0, minX = 0, minZ = 0, maxX = 32, maxZ = 32,
        normal = { x = 0, y = 1, z = 0 }, distance = 0, slopeClass = "flat" },
    } }),
  }
  local player = FieldPlayer.new({
    currentMap = map, fieldX = 4, fieldZ = 13, surfaceId = 0, facing = "south",
    occupancy = function(x, z, surface)
      if x == 4 and z == 14 and surface == 0 then return "map:61:object:0" end
      return nil
    end,
  })
  local camera = { updateFixed = function() end }
  local session = FieldSession.new({ versionId = "heartgold", currentMap = map,
    actor = player, player = player, camera = camera, transition = transition })
  session:updateFixed({ heldDirection = "south", pressedDirection = "south" })
  Assert.equal(#starts, 0)
  Assert.equal(player.fieldZ, 13)
  Assert.equal(player.motion, "idle")
end

function T.standing_warp_starts_only_when_a_step_commits()
  local session, _, starts, warp = warpSession({
    fieldX = 4, fieldZ = 13, warpX = 4, warpZ = 14, commit = true,
  })
  session:updateFixed({ heldDirection = "south" })
  Assert.equal(#starts, 1)
  Assert.equal(starts[1].warp, warp)
  Assert.equal(session.player.fieldZ, 14)
end

function T.arrival_suppression_prevents_immediate_standing_bounce()
  local session, transition, starts = warpSession({
    fieldX = 4, fieldZ = 14, warpX = 4, warpZ = 14, commit = true,
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
    isModal = function(self) return self.modal end,
    step = function(self, snapshot)
      dialogueSteps = dialogueSteps + 1
      received = snapshot
    end,
  }
  local actor = {
    fieldX = 4, fieldZ = 13, worldX = 0, worldY = 0, worldZ = 0,
    surfaceId = 0, facing = "south", motion = "idle",
    updateFixed = function()
      worldSteps.player = worldSteps.player + 1
      return false
    end,
  }
  local camera = { updateFixed = function() worldSteps.camera = worldSteps.camera + 1 end }
  local actors = { step = function() worldSteps.actors = worldSteps.actors + 1 end }
  local playerVisual = { updateFixed = function() worldSteps.visual = worldSteps.visual + 1 end }
  local transition = { phase = "idle", locked = false, updateFixed = function() end }
  local map = { mapId = 61, cameraType = 4 }
  local session = FieldSession.new({
    versionId = "heartgold", currentMap = map,
    actor = actor, player = actor, camera = camera, transition = transition,
    actors = actors, playerVisual = playerVisual, dialogue = dialogue,
  })
  return session, worldSteps, function() return dialogueSteps, received end, dialogue
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
  local map = { mapId = 61, fieldData = { events = { warps = {} } } }
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
  input:pressAction()
  local actor = {
    fieldX = 4, fieldZ = 14, worldX = 0, worldY = 0, worldZ = 0,
    surfaceId = 0, facing = "south", motion = "idle",
    updateFixed = function() return false end,
  }
  local transition = {
    phase = "fade_in", locked = true,
    updateFixed = function(self)
      self.phase, self.locked = "idle", false
      self.completed = { destinationMapId = 60 }
    end,
  }
  local camera = { updateFixed = function() end }
  local map = { mapId = 61, cameraType = 4 }
  local session = FieldSession.new({
    versionId = "heartgold", currentMap = map,
    actor = actor, player = actor, camera = camera, transition = transition,
    input = input,
  })
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
    consume = function(_, intent)
      consumed = intent
      interactions.consumedIntent = intent
      return opts.consumed ~= false
    end,
  }
  local steps = 0
  local actor = {
    fieldX = 4, fieldZ = 14, worldX = 0, worldY = 0, worldZ = 0,
    surfaceId = 0, facing = "north", motion = "idle",
    updateFixed = function()
      steps = steps + 1
      return false
    end,
  }
  local camera = { updateFixed = function() end }
  local actors = { step = function() end }
  local transition = { phase = "idle", locked = false, updateFixed = function() end }
  local map = { mapId = 61, cameraType = 4 }
  local session = FieldSession.new({
    versionId = "heartgold", currentMap = map,
    actor = actor, player = actor, camera = camera, transition = transition,
    actors = actors, interactions = interactions,
  })
  return session, actor, interactions, function() return steps end
end

function T.consumed_interaction_owns_the_tick()
  local session, actor, interactions, steps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session:updateFixed({ actionPressed = true, heldDirection = "north" })
  assert(interactions.resolveSnapshot, "the resolver must have been consulted")
  assert(interactions.consumedIntent, "the resolved intent must be dispatched")
  Assert.equal(steps(), 0, "a consumed interaction blocks movement on the same tick")
  Assert.equal(actor.facing, "north", "the held direction did not start a step")
  Assert.equal(session.tick, 1)
end

function T.unresolved_interaction_falls_through_to_movement()
  local session, actor, interactions, steps = interactionSession()
  session:updateFixed({ actionPressed = true, heldDirection = "north" })
  Assert.equal(steps(), 1, "a nil intent leaves the tick to movement")
  Assert.equal(actor.facing, "north")
end

function T.unconsumed_interaction_does_not_own_the_tick()
  local session, actor, interactions, steps = interactionSession({
    intent = { kind = "background" },
    consumed = false,
  })
  session:updateFixed({ actionPressed = true, heldDirection = "north" })
  Assert.equal(steps(), 1, "a rejected intent does not block movement")
  Assert.equal(actor.facing, "north")
end

function T.interaction_resolve_snapshot_carries_the_player_state()
  local session, actor, interactions = interactionSession({
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
  local session, actor, interactions = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  actor.motion = "walking"
  session:updateFixed({ actionPressed = true })
  Assert.isNil(interactions.resolveSnapshot, "a moving player is never asked to interact")
end

function T.interaction_never_resolves_without_the_action_edge()
  local session, actor, interactions = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session:updateFixed({ actionDown = true, heldDirection = "north" })
  Assert.isNil(interactions.resolveSnapshot, "held Action alone never resolves")
end

function T.interaction_never_resolves_under_a_locked_transition_or_modal()
  local session, actor, interactions, steps = interactionSession({
    intent = { kind = "object", object = { actorId = "map:61:object:0" } },
  })
  session.transition.locked = true
  session:updateFixed({ actionPressed = true })
  Assert.isNil(interactions.resolveSnapshot, "a locked transition owns the tick")
  Assert.equal(steps(), 0)

  session.transition.locked = false
  local modal = { isModal = function() return true end, step = function() end }
  session.dialogue = modal
  session:updateFixed({ actionPressed = true })
  Assert.isNil(interactions.resolveSnapshot, "modal ownership blocks new interactions")
end

-- The session captures the player's walking state before the movement update
-- and hands it to the pose clock, so a two-tile walk (16 ticks, the ROM's full
-- gait range) keeps one continuous phase instead of restarting at each commit.
function T.a_two_tile_walk_keeps_one_phase_across_the_session_ticks()
  local map = {
    mapId = 61, cameraType = 4, coordinateOrigin = { x = 0, z = 0 },
    fieldData = { events = { warps = {} } },
    permissions = {
      containsLocal = function(_, x, z) return x >= 0 and x < 32 and z >= 0 and z < 32 end,
      isBlockedLocal = function() return false end,
    },
    terrain = TerrainSurface.new({ plates = {
      { id = 0, minX = 0, minZ = 0, maxX = 32, maxZ = 32,
        normal = { x = 0, y = 1, z = 0 }, distance = 0, slopeClass = "flat" },
    } }),
  }
  local player = FieldPlayer.new({ currentMap = map, fieldX = 4, fieldZ = 13,
    surfaceId = 0, facing = "south", occupancy = function() return nil end })
  local visual = FieldPlayerVisual.new({
    player = player, spriteId = 0, visualDef = FieldActorFixture.visual(0),
  })
  local camera = { updateFixed = function() end }
  local session = FieldSession.new({ versionId = "heartgold", currentMap = map,
    actor = player, player = player, camera = camera, playerVisual = visual })

  session:updateFixed({ heldDirection = "east", pressedDirection = "east" })
  for tick = 2, 16 do session:updateFixed({ heldDirection = "east" }) end

  Assert.equal(player.fieldX, 6, "two eight-tick steps committed")
  Assert.equal(player.motion, "idle")
  Assert.equal(visual.pose, "walk")
  Assert.equal(visual.poseTick, 16, "the session never lets the gait phase restart mid-walk")
end

return T
