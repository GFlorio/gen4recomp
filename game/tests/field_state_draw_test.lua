-- FieldState presentation reads resolve through the canonical runtime
-- objects: the flattened scene reads mapDraws/buildingDraws off
-- `runtimeMap.sceneRuntime`, the renderer receives that scene runtime, and
-- the developer HUD reports the player's state. The runtime-level actor and
-- runtime aliases are gone, so these reads must not depend on them.

local Assert = require("tests.support.Assert")
local FieldState = require("game.src.game.FieldState")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local function actorRecord(actorId, spriteId)
  return {
    actorId = actorId,
    spriteId = spriteId,
    world = { x = 0, y = 0, z = 0 },
    facing = "south",
    pose = "idle",
    poseTick = 0,
    visible = true,
  }
end

local function presentationEntry(spriteId)
  local visual = FieldActorFixture.visual(spriteId, { frameCount = 2 })
  local meshes = {}
  for frameIndex = 1, visual.render.frameCount do
    meshes[frameIndex] = { frameIndex = frameIndex }
  end
  return { spriteId = spriteId, visual = visual, image = {}, meshes = meshes }
end

local function presentationAssets(entries)
  return {
    entries = entries,
    acquisitions = {},
    releases = {},
    acquire = function(self, spriteId)
      self.acquisitions[spriteId] = (self.acquisitions[spriteId] or 0) + 1
      return assert(self.entries[spriteId])
    end,
    resident = function(self, spriteId)
      return self.entries[spriteId]
    end,
    release = function(self, spriteId)
      self.releases[spriteId] = (self.releases[spriteId] or 0) + 1
    end,
    dispose = function(self)
      self.disposed = true
    end,
  }
end

local function presentationState(assets, actorIds)
  local actors = { revision = 0, spriteIds = actorIds }
  function actors:visualRevision()
    return self.revision
  end
  function actors:collectSpriteIds(out)
    for spriteId in pairs(self.spriteIds) do
      out[spriteId] = true
    end
  end
  local runtime = {
    update = function() end,
    dispose = function() end,
    actors = actors,
    playerVisual = {
      spriteId = 99,
      drawRecord = function()
        return actorRecord("field:player", 99)
      end,
    },
    runtimeMap = { sceneRuntime = { mapDraws = {}, buildingDraws = {} } },
  }
  return setmetatable({
    runtime = runtime,
    presentationActorAssets = assets,
    _presentationSpriteRefs = {},
  }, FieldState),
    actors,
    runtime
end

-- A bare FieldState over a fake runtime that carries only the canonical
-- fields: no `runtime` sceneRuntime alias and no `actor` player alias.
local function stateWith(runtime)
  return setmetatable({
    runtime = runtime,
    renderer = {
      draw = function()
        error("renderer should be stubbed by the test")
      end,
    },
  }, FieldState)
end

function T.world_draws_read_the_scene_runtime_of_the_runtime_map()
  local sceneRuntime = {
    mapDraws = { { kind = "map" } },
    buildingDraws = { { kind = "building" } },
  }
  local state = stateWith({
    runtimeMap = { sceneRuntime = sceneRuntime },
    playerVisual = {
      drawRecord = function()
        return { visible = false }
      end,
    },
    actors = {
      drawRecords = function()
        return {}
      end,
    },
  })
  local draws = state:_worldDraws(0.5)
  Assert.equal(#draws, 2)
  Assert.equal(draws[1].kind, "map")
  Assert.equal(draws[2].kind, "building")
end

-- A live presentation runtime always carries the transition, dialogue, and
-- menu host; draw consults all three unconditionally, and the renderer
-- receives the scene runtime.
function T.draw_passes_the_scene_runtime_and_queries_the_menu_host()
  local sceneRuntime = {
    mapDraws = { { kind = "map" } },
    buildingDraws = { { kind = "building" } },
  }
  local presentations = 0
  local received
  local state = setmetatable({
    runtime = {
      runtimeMap = { mapId = 61, mapSymbol = "MAP_NEW_BARK", sceneRuntime = sceneRuntime },
      player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
      playerVisual = {
        drawRecord = function()
          return { visible = false }
        end,
      },
      actors = {
        drawRecords = function()
          return {}
        end,
      },
      session = {
        renderAlpha = function()
          return 0.5
        end,
      },
      viewport = {
        width = 640,
        height = 480,
        worldViewport = { x = 0, y = 0, width = 640, height = 480 },
      },
      transition = { fadeAlpha = 0 },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      menuHost = {
        presentation = function()
          presentations = presentations + 1
          return nil
        end,
      },
    },
    renderer = {
      draw = function(_, scene, camera, worldDraws)
        received = { scene = scene, camera = camera, worldDraws = worldDraws }
      end,
    },
  }, FieldState)
  state:draw()
  Assert.equal(received.scene, sceneRuntime, "the renderer receives the runtime map's scene runtime")
  Assert.equal(received.camera, nil, "the draw path forwards the state's camera (absent in this fake)")
  Assert.equal(#received.worldDraws, 2)
  Assert.equal(presentations, 1, "draw always queries the menu host presentation")
end

function T.draw_hud_reads_the_player_state()
  local state = stateWith({
    runtimeMap = { mapId = 61, mapSymbol = "MAP_NEW_BARK" },
    player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
  })
  state:_drawHud()
end

-- A live presentation runtime always carries the menu host, so a state
-- without one has no zombie mode: drawing it is a programming error, not a
-- silently skipped menu query.
function T.draw_without_a_menu_host_is_a_programming_error()
  local state = setmetatable({
    runtime = {
      runtimeMap = { mapId = 61, mapSymbol = "MAP_NEW_BARK", sceneRuntime = { mapDraws = {}, buildingDraws = {} } },
      player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
      playerVisual = {
        drawRecord = function()
          return { visible = false }
        end,
      },
      actors = {
        drawRecords = function()
          return {}
        end,
      },
      session = {
        renderAlpha = function()
          return 0.5
        end,
      },
      viewport = { width = 640, height = 480, worldViewport = { x = 0, y = 0, width = 640, height = 480 } },
      transition = { fadeAlpha = 0 },
      dialogue = {
        isModal = function()
          return false
        end,
      },
    },
    renderer = { draw = function() end },
  }, FieldState)
  Assert.throws(function()
    state:draw()
  end)
end

function T.presentation_residency_is_distinct_change_driven_and_balanced()
  local assets = presentationAssets({ [99] = presentationEntry(99), [34] = presentationEntry(34) })
  local state, actors = presentationState(assets, { [99] = true })
  state:update(0.016)
  state:update(0.016)
  Assert.equal(assets.acquisitions[99], 1, "player and sharing actors use one presentation reference")

  actors.revision = actors.revision + 1
  actors.spriteIds[34] = true
  state:update(0.016)
  Assert.equal(assets.acquisitions[34], 1, "an arriving sprite is acquired once")

  actors.revision = actors.revision + 1
  actors.spriteIds[34] = nil
  state:update(0.016)
  Assert.equal(assets.releases[34], 1, "a sprite is released after its last actor leaves")

  state.runtime.playerVisual.spriteId = 34
  state:update(0.016)
  Assert.equal(assets.acquisitions[34], 2, "a changed player sprite is synchronized")

  state:dispose()
  Assert.equal(assets.releases[99], 1, "disposal releases the player reference")
  Assert.equal(assets.releases[34], 2, "disposal releases the changed player reference")
  Assert.isTrue(assets.disposed)
end

function T.presentation_sync_releases_partial_acquisition_on_failure()
  local assets = presentationAssets({ [99] = presentationEntry(99), [34] = presentationEntry(34) })
  local acquireCalls = 0
  local released = 0
  assets.acquire = function(self, spriteId)
    acquireCalls = acquireCalls + 1
    if acquireCalls == 2 then
      error("injected presentation acquire failure")
    end
    return assert(self.entries[spriteId])
  end
  assets.release = function()
    released = released + 1
  end
  local state = presentationState(assets, { [34] = true })
  local err = Assert.throws(function()
    state:update(0.016)
  end)
  Assert.isTrue(tostring(err):find("injected presentation acquire failure", 1, true) ~= nil)
  Assert.equal(acquireCalls, 2)
  Assert.equal(released, 1, "the earlier acquisition is released after a later failure")
  Assert.isNil(next(state._presentationSpriteRefs))
end

function T.presentation_sync_restarts_for_a_replaced_actor_manager()
  local assets = presentationAssets({ [99] = presentationEntry(99), [34] = presentationEntry(34) })
  local state, actors, runtime = presentationState(assets, { [34] = true })
  state:update(0.016)
  Assert.equal(assets.acquisitions[99], 1)
  Assert.equal(assets.acquisitions[34], 1)

  local replacement = {
    visualRevision = function()
      return 0
    end,
    collectSpriteIds = function() end,
  }
  runtime.actors = replacement
  state:update(0.016)

  Assert.equal(assets.releases[34], 1, "the old manager's sprite is released")
  Assert.equal(state._lastActorManager, replacement)
  Assert.equal(actors.revision, 0)
end

function T.draw_rejects_a_sprite_without_presentation_residency()
  local acquisitions = 0
  local state = setmetatable({
    runtime = {
      playerVisual = {
        drawRecord = function()
          return actorRecord("field:player", 99)
        end,
      },
      actors = {
        drawRecords = function()
          return {}
        end,
      },
    },
    presentationActorAssets = {
      resident = function()
        return nil
      end,
      acquire = function()
        acquisitions = acquisitions + 1
        return nil
      end,
    },
  }, FieldState)
  Assert.throws(function()
    state:_actorDraws(0)
  end)
  Assert.equal(acquisitions, 0)
end

-- Presentation reads must go through the explicit `runtime` reference: the
-- catch-all proxy that forwarded any unknown instance read into the runtime is
-- gone, so a forwarded field name on the instance itself is nil and a typo
-- cannot silently resolve. The reads go through the instance (not rawget, which
-- would bypass the proxy and pass even with it present).
function T.runtime_fields_are_not_forwarded_onto_the_instance()
  local state = stateWith({
    viewport = { width = 640, height = 480 },
    session = {
      renderAlpha = function()
        return 0.5
      end,
    },
  })
  Assert.isNil(state["viewport"])
  Assert.isNil(state["session"])
  Assert.isNil(state["player"])
  Assert.isNil(state["zoom"])
end

return { tests = T }
