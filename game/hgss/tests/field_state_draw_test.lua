-- FieldState presentation reads resolve through the canonical runtime
-- objects: ordered world parts read mapDraws/staticBuildingDraws/
-- animatedBuildingDraws off `runtimeMap.sceneRuntime`, the renderer receives
-- that scene runtime, and the developer HUD reports the player's state. The
-- runtime-level actor and runtime aliases are gone, so these reads must not
-- depend on them.

local Assert = require("tests.support.Assert")
local FieldState = require("game.hgss.src.field.FieldState")
local FieldSession = require("libs.hgss.src.field.FieldSession")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorManager = require("libs.hgss.src.field.FieldActorManager")
local FieldEventState = require("libs.hgss.src.field.FieldEventState")
local FieldViewport = require("libs.hgss.src.presentation.FieldViewport")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")
local TerrainSurface = require("libs.hgss.src.field.TerrainSurface")

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
  return {
    spriteId = spriteId,
    visual = visual,
    image = {},
    meshes = meshes,
    billboardScales = { [visual.render.geometry] = { 1, 1, 1 } },
  }
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
    runtimeMap = { sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} } },
    fieldEntranceIndicator = {
      status = function()
        return { visible = false }
      end,
    },
  }
  return setmetatable({
    runtime = runtime,
    presentationActorAssets = assets,
    _presentationSpriteRefs = {},
    _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
    _actorAssetLookup = function(spriteId)
      return assert(assets:resident(spriteId), "field actor presentation visual is not resident")
    end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    fieldEntranceIndicatorRenderer = {
      drawItems = function()
        return {}
      end,
      dispose = function() end,
    },
    fieldEmoteRenderer = {
      drawItems = function()
        return {}
      end,
      dispose = function() end,
    },
  }, FieldState),
    actors,
    runtime
end

---@param assets table
---@param actors FieldActorManager
---@return FieldState state
local function presentationStateWithActors(assets, actors)
  local state, _, runtime = presentationState(assets, {})
  runtime.actors = actors
  runtime.dispose = function()
    actors:dispose()
  end
  return state
end

local ACTOR_POLICY = {
  variableSprites = { first = 101, last = 117, variableBase = 0x4020 },
}

local function actorEvent(objectEventId, spriteId)
  return {
    index = objectEventId,
    objectEventId = objectEventId,
    spriteId = spriteId,
    movementType = "stationary",
    type = 0,
    eventFlag = 0,
    scriptId = 1,
    facingDirection = "south",
    facingDirectionRaw = 1,
    param0 = 0,
    param1 = 0,
    param2 = 0,
    xRange = 0,
    yRange = 0,
    x = 2 + objectEventId,
    z = 3,
    y = 0,
  }
end

---@param mapId integer
---@param events table[]
---@return RuntimeFieldMap
local function actorMap(mapId, events)
  return {
    mapId = mapId,
    mapSection = "test-section",
    mapSymbol = "test-map",
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, localX, localZ)
        return localX >= 0 and localX < 32 and localZ >= 0 and localZ < 32
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
    fieldData = { events = { objects = events } },
    scene = {},
    cameraType = 4,
    release = function() end,
    updateAnimated = function() end,
  } --[[@as RuntimeFieldMap]]
end

---@return FieldActorAssets
local function actorDefinitionAssets()
  local known = { [99] = true, [34] = true }
  local assets = { references = {} }
  function assets:knows(spriteId)
    return known[spriteId] == true
  end
  function assets:acquire(spriteId)
    self.references[spriteId] = (self.references[spriteId] or 0) + 1
    return { spriteId = spriteId, visual = {} }
  end
  function assets:release(spriteId)
    local count = assert(self.references[spriteId])
    assert(count > 0)
    self.references[spriteId] = count - 1
  end
  return assets --[[@as FieldActorAssets]]
end

local function realActorManager()
  local eventState = FieldEventState.new()
  local manager = FieldActorManager.new({ assets = actorDefinitionAssets(), policy = ACTOR_POLICY })
  return manager, eventState
end

-- A bare FieldState over a fake runtime that carries only the canonical
-- fields: no `runtime` sceneRuntime alias and no `actor` player alias.
local function stateWith(runtime)
  runtime.fieldEntranceIndicator = {
    status = function()
      return { visible = false }
    end,
  }
  return setmetatable({
    runtime = runtime,
    _pollPresentationTopology = false,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    renderer = {
      draw = function()
        error("renderer should be stubbed by the test")
      end,
    },
    fieldEntranceIndicatorRenderer = {
      drawItems = function()
        return {}
      end,
    },
    fieldEmoteRenderer = {
      drawItems = function()
        return {}
      end,
    },
  }, FieldState)
end

function T.world_parts_refresh_replaced_scene_neighbor_and_actor_draws()
  local mapDraws = { { kind = "map" } }
  local staticBuildingDraws = { { kind = "static-building" } }
  local animatedBuildingDraws = { { kind = "animated-building" } }
  local neighborDraws = { { kind = "neighbor" } }
  local sceneRuntime = {
    mapDraws = mapDraws,
    staticBuildingDraws = staticBuildingDraws,
    animatedBuildingDraws = animatedBuildingDraws,
  }
  local state = stateWith({
    runtimeMap = { sceneRuntime = sceneRuntime, neighborRuntime = { draws = neighborDraws } },
  })
  local actorDraws = { { kind = "actor" } }
  local currentActorDraws = actorDraws
  state._actorDraws = function(_, alpha)
    Assert.equal(alpha, 0.5)
    return currentActorDraws
  end

  local parts = state:_worldParts(0.5)
  Assert.isTrue(parts == state.worldParts, "FieldState retains one parts array")
  Assert.isTrue(parts[1] == mapDraws)
  Assert.isTrue(parts[2] == staticBuildingDraws)
  Assert.isTrue(parts[3] == animatedBuildingDraws)
  Assert.isTrue(parts[4] == neighborDraws)
  Assert.isTrue(parts[6] == state.worldActorItems)
  Assert.equal(parts[6][1], actorDraws[1])

  local nextMapDraws = { { kind = "next-map" } }
  local nextAnimatedBuildingDraws = { { kind = "next-animated-building" } }
  local nextActorDraws = { { kind = "next-actor" } }
  sceneRuntime.mapDraws = nextMapDraws
  sceneRuntime.animatedBuildingDraws = nextAnimatedBuildingDraws
  state.runtime.runtimeMap.neighborRuntime = nil
  currentActorDraws = nextActorDraws

  local refreshed = state:_worldParts(0.5)
  Assert.isTrue(refreshed == parts, "refresh does not replace the parts array")
  Assert.isTrue(refreshed[1] == nextMapDraws)
  Assert.isTrue(refreshed[2] == staticBuildingDraws, "the static building list is not rebuilt on a fixed tick")
  Assert.isTrue(
    refreshed[3] == nextAnimatedBuildingDraws,
    "fixed-tick animated building replacement reaches the renderer"
  )
  Assert.deepEqual(refreshed[4], {})
  Assert.isTrue(refreshed[6] == state.worldActorItems)
  Assert.equal(refreshed[6][1], nextActorDraws[1])
end

-- A live presentation runtime always carries the transition, dialogue, and
-- menu host; draw consults all three unconditionally, and the renderer
-- receives the scene runtime.
function T.draw_passes_the_scene_runtime_and_queries_the_menu_host()
  local sceneRuntime = {
    mapDraws = { { kind = "map" } },
    staticBuildingDraws = { { kind = "static-building" } },
    animatedBuildingDraws = { { kind = "animated-building" } },
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
      fieldEntranceIndicator = {
        status = function()
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
      destinationWorldPresentable = function()
        return true
      end,
      acknowledgeDestinationPresentation = function() end,
      viewport = FieldViewport.new(640, 480, { mode = "expanded" }),
      camera = { zoom = 1 },
      transition = { fadeAlpha = 0 },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      signpost = {
        isModal = function()
          return false
        end,
      },
      applicationHost = {
        status = function()
          return { phase = "closed", fadeAlpha = 0 }
        end,
      },
      menuHost = {
        presentation = function()
          presentations = presentations + 1
          return nil
        end,
      },
      startMenuPlacement = nil,
      resizePresentation = function() end,
    },
    _pollPresentationTopology = true,
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
    renderer = {
      draw = function(_, scene, camera, worldParts)
        received = { scene = scene, camera = camera, worldParts = worldParts }
      end,
    },
    _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
    _actorAssetLookup = function()
      error("no actor in this scenario is visible, so the asset lookup must not run")
    end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    fieldEntranceIndicatorRenderer = {
      drawItems = function()
        return {}
      end,
    },
    fieldEmoteRenderer = {
      drawItems = function()
        return {}
      end,
    },
  }, FieldState)
  state:draw()
  Assert.equal(received.scene, sceneRuntime, "the renderer receives the runtime map's scene runtime")
  Assert.equal(received.camera, state.runtime.camera, "the draw path forwards the runtime camera")
  Assert.isTrue(received.worldParts == state.worldParts)
  Assert.isTrue(received.worldParts[1] == sceneRuntime.mapDraws)
  Assert.isTrue(received.worldParts[2] == sceneRuntime.staticBuildingDraws)
  Assert.isTrue(received.worldParts[3] == sceneRuntime.animatedBuildingDraws)
  Assert.deepEqual(received.worldParts[4], {})
  Assert.deepEqual(received.worldParts[5], {})
  Assert.equal(presentations, 1, "draw always queries the menu host presentation")
end

function T.draw_sends_static_actor_models_to_world_and_billboards_to_presentation()
  local sceneRuntime = {
    mapDraws = {},
    staticBuildingDraws = {},
    animatedBuildingDraws = {},
  }
  local staticModel = { kind = "actor", billboardProjection = false }
  local sprite = { kind = "actor", billboardProjection = true }
  local received
  local state = setmetatable({
    runtime = {
      runtimeMap = { sceneRuntime = sceneRuntime },
      playerVisual = {
        drawRecord = function()
          return { visible = false }
        end,
      },
      fieldEntranceIndicator = {
        status = function()
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
      destinationWorldPresentable = function()
        return true
      end,
      acknowledgeDestinationPresentation = function() end,
      viewport = FieldViewport.new(640, 480, { mode = "expanded" }),
      camera = { zoom = 1 },
      transition = { fadeAlpha = 0 },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      signpost = {
        isModal = function()
          return false
        end,
      },
      applicationHost = {
        status = function()
          return { phase = "closed", fadeAlpha = 0 }
        end,
      },
      menuHost = {
        presentation = function()
          return nil
        end,
      },
      resizePresentation = function() end,
    },
    _pollPresentationTopology = true,
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
    renderer = {
      draw = function(_, _, _, worldParts, spriteItems)
        received = { worldParts = worldParts, spriteItems = spriteItems }
      end,
    },
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    fieldEntranceIndicatorRenderer = {
      drawItems = function()
        return {}
      end,
    },
    fieldEmoteRenderer = {
      drawItems = function()
        return {}
      end,
    },
  }, FieldState)
  state._actorDraws = function()
    return { staticModel, sprite }
  end

  state:draw()
  Assert.equal(received.worldParts[6][1], staticModel)
  Assert.equal(received.spriteItems[1], sprite)
  Assert.equal(#received.worldParts[6], 1)
  Assert.equal(#received.spriteItems, 1)
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
      runtimeMap = {
        mapId = 61,
        mapSymbol = "MAP_NEW_BARK",
        sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
      },
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
      destinationWorldPresentable = function()
        return true
      end,
      acknowledgeDestinationPresentation = function() end,
      viewport = FieldViewport.new(640, 480, { mode = "expanded" }),
      camera = { zoom = 1 },
      transition = { fadeAlpha = 0 },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      signpost = {
        isModal = function()
          return false
        end,
      },
      applicationHost = {
        status = function()
          return { phase = "closed", fadeAlpha = 0 }
        end,
      },
      startMenuPlacement = nil,
      resizePresentation = function() end,
    },
    _pollPresentationTopology = true,
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
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

function T.activated_actor_revision_refreshes_presentation_assets()
  local assets = presentationAssets({ [99] = presentationEntry(99), [34] = presentationEntry(34) })
  local actors, eventState = realActorManager()
  actors:enterMap(actorMap(61, { actorEvent(0, 99) }), eventState)
  local state = presentationStateWithActors(assets, actors)
  local revisionBeforeActivation = actors:visualRevision()

  state:update(0.016)
  Assert.isNil(assets.acquisitions[34], "a map that was never activated has no presentation assets")

  actors:enterMap(actorMap(60, { actorEvent(1, 34) }), eventState)
  Assert.isTrue(
    actors:visualRevision() > revisionBeforeActivation,
    "activating a nonempty actor map must invalidate presentation synchronization"
  )
  state:update(0.016)
  Assert.equal(assets.acquisitions[34], 1, "the published actor sprite is acquired before drawing")

  local destinationDraw
  for _, item in ipairs(state:_actorDraws(0.5)) do
    if item.actorId == "map:60:object:1" then
      destinationDraw = item
      break
    end
  end
  Assert.notNil(destinationDraw, "the published destination actor has a presentation draw item")
  state:dispose()
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
  local assets = {
    resident = function(_, _)
      return nil
    end,
    acquire = function()
      acquisitions = acquisitions + 1
      return nil
    end,
  }
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
    presentationActorAssets = assets,
    _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
    _actorAssetLookup = function(spriteId)
      return assert(assets:resident(spriteId), "field actor presentation visual is not resident")
    end,
  }, FieldState)
  Assert.throws(function()
    state:_actorDraws(0)
  end)
  Assert.equal(acquisitions, 0)
end

function T.actor_draws_reuse_state_storage_without_acquiring_assets()
  local assets = presentationAssets({ [99] = presentationEntry(99) })
  local state, actors = presentationState(assets, { [99] = true })
  actors.records = { actorRecord("map:61:object:0", 99) }
  function actors:drawRecords()
    return self.records
  end

  local items = state:_actorDraws(0.5)
  local actorItem = items[2]
  actors.records[1].world.x = 7
  local updated = state:_actorDraws(0.5)

  Assert.isTrue(updated == items, "FieldState reuses the actor item array")
  Assert.isTrue(updated[2] == actorItem, "FieldState reuses the actor item skeleton")
  Assert.equal(updated[2].transform[13], 7)
  Assert.isNil(assets.acquisitions[99], "draw reads residency without acquiring assets")

  state:dispose()
  Assert.isNil(state._actorRecords, "disposal drops borrowed actor records")
  Assert.isNil(state._actorDrawStorage, "disposal drops borrowed draw items")
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

function T.destination_world_is_not_drawn_before_entry_presentation_is_ready()
  local draws = 0
  local state = setmetatable({
    runtime = {
      runtimeMap = { sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} } },
      fieldEntranceIndicator = {
        status = function()
          return { visible = false }
        end,
      },
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
      destinationWorldPresentable = function()
        return false
      end,
      acknowledgeDestinationPresentation = function()
        error("hidden destination must not be acknowledged")
      end,
      viewport = FieldViewport.new(640, 480, { mode = "expanded" }),
      camera = { zoom = 1 },
      transition = { fadeAlpha = 0 },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      signpost = {
        isModal = function()
          return false
        end,
      },
      applicationHost = {
        status = function()
          return { phase = "closed", fadeAlpha = 0 }
        end,
      },
      menuHost = {
        presentation = function()
          return nil
        end,
      },
      resizePresentation = function() end,
    },
    _pollPresentationTopology = false,
    topologyProvider = function()
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 640, height = 480 },
        touch = false,
        role = "world",
      })
    end,
    renderer = {
      draw = function()
        draws = draws + 1
      end,
    },
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
    _actorAssetLookup = function()
      return {}
    end,
  }, FieldState)

  state:draw()
  Assert.equal(draws, 0, "destination world presentation waits for load completion")
end

function T.destination_frames_draw_and_acknowledge_only_after_successful_presentation()
  local function makeState(renderer)
    ---@diagnostic disable: missing-fields
    local session = FieldSession.new({
      versionId = "heartgold",
      currentMap = { fieldData = { events = { warps = {} } }, updateAnimated = function() end },
      player = {
        worldX = 0,
        worldY = 0,
        worldZ = 0,
        motion = "idle",
        updateFixed = function()
          return false
        end,
      },
      camera = { updateFixed = function() end },
      transition = {
        phase = "idle",
        locked = false,
        updateFixed = function() end,
        start = function()
          error("unexpected transition", 2)
        end,
      },
      actors = { step = function() end },
      input = {
        snapshot = function()
          return {}
        end,
        uiSnapshot = function()
          return {}
        end,
        clearEdges = function() end,
      },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      scriptScheduler = {
        step = function() end,
        playerInputLocked = function()
          return false
        end,
        playerInputOwned = function()
          return false
        end,
        foregroundEnvironmentId = function()
          return nil
        end,
      },
      scriptClient = { consume = function() end },
      enterMapActors = function() end,
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
      applicationHost = {
        isActive = function()
          return false
        end,
        updateFixed = function() end,
        requestOpen = function()
          return false
        end,
        requestReopen = function() end,
        takeReopen = function()
          return false
        end,
      },
      interactions = {
        resolve = function()
          return nil
        end,
      },
      bagUnlocked = function()
        return true
      end,
      fieldEntranceIndicator = {
        updateFixed = function() end,
      },
      eventResolver = {
        resolveCoordinate = function() end,
        resolvePassiveSign = function() end,
      },
      eventState = {
        getVar = function()
          return 0
        end,
      },
    })
    ---@diagnostic enable: missing-fields
    session.mapEntryStage = "transition"
    local runtime = {
      runtimeMap = { sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} } },
      fieldEntranceIndicator = {
        status = function()
          return { visible = false }
        end,
      },
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
      session = session,
      destinationWorldPresentable = function(self)
        return self.session:destinationWorldPresentable()
      end,
      acknowledgeDestinationPresentation = function(self)
        self.session:acknowledgeDestinationPresentation()
      end,
      viewport = FieldViewport.new(640, 480, { mode = "expanded" }),
      camera = { zoom = 1 },
      transition = { fadeAlpha = 0 },
      dialogue = {
        isModal = function()
          return false
        end,
      },
      signpost = {
        isModal = function()
          return false
        end,
      },
      applicationHost = {
        status = function()
          return { phase = "closed", fadeAlpha = 0 }
        end,
      },
      menuHost = {
        presentation = function()
          return nil
        end,
      },
      resizePresentation = function() end,
    }
    local state = setmetatable({
      runtime = runtime,
      _pollPresentationTopology = false,
      renderer = renderer,
      worldParts = {},
      worldActorItems = {},
      spriteItems = {},
      _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
      _actorAssetLookup = function()
        return {}
      end,
      fieldEntranceIndicatorRenderer = {
        drawItems = function()
          return {}
        end,
      },
      fieldEmoteRenderer = {
        drawItems = function()
          return {}
        end,
      },
    }, FieldState)
    return state, session
  end

  local draws = 0
  local state, session = makeState({
    draw = function()
      draws = draws + 1
    end,
  })
  state:draw()
  Assert.equal(draws, 0)
  session.mapEntryStage = "await_presentation"
  state:draw()
  Assert.equal(draws, 1)
  Assert.equal(session.mapEntryStage, "resume")
  session.mapEntryStage = "resume_running"
  state:draw()
  session.mapEntryStage = nil
  state:draw()
  Assert.equal(draws, 3)

  local failedDraws = 0
  local failedState, failedSession = makeState({
    draw = function()
      failedDraws = failedDraws + 1
      error("destination renderer failed")
    end,
  })
  failedSession.mapEntryStage = "await_presentation"
  Assert.throws(function()
    failedState:draw()
  end)
  Assert.equal(failedDraws, 1)
  Assert.equal(failedSession.mapEntryStage, "await_presentation")
end

return { tests = T }
