-- Fixed-step session tests prove deterministic tick counts, catch-up capping,
-- and that the camera consumes the placeholder actor's continuous 3D target.

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldSession = require("libs.engine.src.FieldSession")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function session()
  local targets = {}
  local camera = { updateFixed = function(_, target)
    targets[#targets + 1] = { x = target.x, y = target.y, z = target.z }
  end }
  local actor = { worldX = 1.25, worldY = 2.5, worldZ = 3.75 }
  return FieldSession.new({ versionId = "heartgold", currentMap = { mapId = 61 },
    actor = actor, camera = camera }), targets
end

function T.fixed_ticks_are_render_cadence_independent()
  local a = session()
  a:update(1 / 30)
  local b = session()
  b:update(1 / 60)
  b:update(1 / 60)
  Assert.equal(a.tick, 2)
  Assert.equal(b.tick, 2)
end

function T.caps_catch_up_and_counts_discarded_ticks()
  local s = session()
  s:update(10 / 60)
  Assert.equal(s.tick, 5)
  Assert.equal(s.discardedTicks, 5)
end

function T.camera_follows_the_actor_xyz_each_fixed_tick()
  local s, targets = session()
  s:update(1 / 60)
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
  local s = FieldSession.new({
    versionId = "heartgold", currentMap = { mapId = 61, cameraType = 4 },
    actor = actor, player = actor, camera = { updateFixed = function() end },
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
  local s = FieldSession.new({
    versionId = "heartgold", currentMap = { mapId = 61, cameraType = 4 },
    actor = actor, player = actor, camera = { updateFixed = function() end },
    transition = transition, playerVisual = playerVisual,
  })
  s:updateFixed({})
  s:updateFixed({})
  Assert.equal(steps, 2)

  transition.locked = true
  s:updateFixed({})
  Assert.equal(steps, 2, "a locked transition owns the tick, so no pose advances")
end

function T.trace_is_identical_across_render_delta_patterns()
  local function run(pattern)
    local records = {}
    local actor = {
      fieldX = 1, fieldZ = 2, worldX = 0, worldY = 0, worldZ = 0,
      surfaceId = 3, facing = "north", motion = "walking",
    }
    function actor:updateFixed()
      self.worldY = self.worldY + 0.125
    end
    local camera = {
      updateFixed = function(self, target)
        self.cameraSourceY, self.cameraAppliedY = target.y, target.y
      end,
    }
    local s = FieldSession.new({
      versionId = "heartgold", currentMap = { mapId = 60, cameraType = 0 },
      actor = actor, player = actor, camera = camera,
      trace = function(record) records[#records + 1] = record end,
    })
    for _, dt in ipairs(pattern) do s:update(dt, {}) end
    return records
  end
  local sixtieths = {}
  local oneTwentieths = {}
  for _ = 1, 24 do sixtieths[#sixtieths + 1] = 1 / 60 end
  for _ = 1, 8 do oneTwentieths[#oneTwentieths + 1] = 1 / 20 end
  Assert.deepEqual(run(sixtieths), run(oneTwentieths))
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
  local session = FieldSession.new({
    versionId = "heartgold", currentMap = { mapId = 61, cameraType = 4 },
    actor = actor, player = actor, camera = camera, transition = transition,
    actors = actors, playerVisual = playerVisual, dialogue = dialogue,
  })
  return session, worldSteps, function() return dialogueSteps, received end
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
  local session, worldSteps, dialogueState = dialogueSession()
  session:updateFixed({})
  Assert.equal(worldSteps.player, 0)
  -- The dialogue closes (its own step dispatches the completion); the next
  -- session tick runs the world again.
  session.dialogue.modal = false
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
  local session = FieldSession.new({
    versionId = "heartgold", currentMap = { mapId = 61, cameraType = 4 },
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

return T
