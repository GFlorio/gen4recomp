-- FieldState presentation reads resolve through the canonical runtime
-- objects: the flattened scene reads mapDraws/buildingDraws off
-- `runtimeMap.sceneRuntime`, the renderer receives that scene runtime, and
-- the developer HUD reports the player's state. The runtime-level actor and
-- runtime aliases are gone, so these reads must not depend on them.

local Assert = require("tests.support.Assert")
local FieldState = require("game.src.game.FieldState")

local T = {}

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

function T.draw_passes_the_scene_runtime_to_the_renderer()
  local sceneRuntime = {
    mapDraws = { { kind = "map" } },
    buildingDraws = { { kind = "building" } },
  }
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
end

function T.draw_hud_reads_the_player_state()
  local state = stateWith({
    runtimeMap = { mapId = 61, mapSymbol = "MAP_NEW_BARK" },
    player = { fieldX = 3, fieldZ = 7, worldY = 1.5, surfaceId = 0, facing = "east", motion = "idle" },
  })
  state:_drawHud()
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

return T
