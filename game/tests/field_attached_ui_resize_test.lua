-- Resize coupling: UI scale follows camera.zoom via logicalPixelScale, not
-- host height proportion.

local Assert = require("tests.support.Assert")
local FieldViewport = require("libs.engine.src.FieldViewport")
local FieldZoom = require("libs.engine.src.FieldZoom")
local FieldPresentation = require("data.manifests.field_presentation")
local FieldState = require("game.src.game.FieldState")
local ScreenTopology = require("libs.engine.src.ScreenTopology")

local T = {}

---@class ResizeTestRuntime
---@field resizeCalls integer?
---@field lastResize table?

local function drawState(topologyProvider, pollTopology)
  ---@type ResizeTestRuntime
  local runtime = {
    session = {
      renderAlpha = function()
        return 0
      end,
    },
    runtimeMap = { sceneRuntime = {} },
    camera = { zoom = 1 },
    viewport = {
      worldViewport = {},
      logicalPixelScale = function()
        return 1
      end,
    },
    applicationHost = {
      status = function()
        return { fadeAlpha = 0 }
      end,
    },
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
    menuHost = {
      presentation = function()
        return nil
      end,
    },
    resizePresentation = function(self, width, height, topology)
      self.resizeCalls = (self.resizeCalls or 0) + 1
      self.lastResize = { width, height, topology }
    end,
  }
  local state = setmetatable({
    runtime = runtime,
    topologyProvider = topologyProvider,
    _pollPresentationTopology = pollTopology == true,
    renderer = { draw = function() end },
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
  }, FieldState)
  state._worldParts = function()
    return state.worldParts
  end
  return state, runtime
end

local function oneDisplay(width, height, safeRect)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = width, height = height },
    safeRect = safeRect,
    touch = false,
    role = "world",
  })
end

function T.default_field_draw_does_not_poll_topology_or_resize_runtime()
  local state, runtime = drawState(nil)
  local originalGetDimensions = love.graphics.getDimensions
  love.graphics.getDimensions = function()
    error("default draw must not query presentation dimensions")
  end
  local ok, err = pcall(function()
    state:draw()
    state:draw()
  end)
  love.graphics.getDimensions = originalGetDimensions
  Assert.isTrue(ok, "steady default draws must not perform geometry polling: " .. tostring(err))
  Assert.isNil(runtime.lastResize)
end

function T.resize_event_applies_presentation_geometry_once_before_an_unchanged_draw()
  local topology = oneDisplay(1280, 720)
  local state, runtime = drawState(function()
    return topology
  end)
  state:resize(1280, 720)
  Assert.equal(runtime.resizeCalls, 1)
  Assert.deepEqual(runtime.lastResize, { 1280, 720, topology })

  local originalGetDimensions = love.graphics.getDimensions
  love.graphics.getDimensions = function()
    error("default draw must not poll after an explicit resize")
  end
  local ok, err = pcall(function()
    state:draw()
  end)
  love.graphics.getDimensions = originalGetDimensions
  Assert.isTrue(ok, "unchanged draw must use the event-synchronized geometry: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 1)
end

function T.injected_topology_provider_publishes_one_same_size_structural_change()
  local current = oneDisplay(1280, 720, { x = 0, y = 0, width = 1280, height = 700 })
  local state, runtime = drawState(function()
    return current
  end, true)
  state._lastGeometrySignature = state:_geometrySignature(1280, 720, current)
  current = oneDisplay(1280, 720, { x = 0, y = 20, width = 1280, height = 700 })

  local originalGetDimensions = love.graphics.getDimensions
  love.graphics.getDimensions = function()
    return 1280, 720
  end
  local ok, err = pcall(function()
    state:draw()
    state:draw()
  end)
  love.graphics.getDimensions = originalGetDimensions
  Assert.isTrue(ok, "injected topology polling must remain supported: " .. tostring(err))
  Assert.equal(runtime.resizeCalls, 1)
  Assert.deepEqual(runtime.lastResize, { 1280, 720, current })
end

local function effectiveScaleAtHeight(height)
  local viewport = FieldViewport.new(1280, height, { mode = "expanded" })
  local zoom = FieldZoom.new(FieldPresentation.zoom)
  zoom:resize(viewport.worldViewport.height)
  local effective = zoom:effectiveZoom()
  return viewport:logicalPixelScale(effective), effective, viewport
end

function T.ui_scale_equals_logical_pixel_scale_at_two_heights()
  local scaleA, zoomA = effectiveScaleAtHeight(600)
  local scaleB, zoomB = effectiveScaleAtHeight(720)
  -- With resizeCompensation 0.7, zoom changes with height
  Assert.isTrue(zoomA ~= zoomB, "resize must change effective zoom per field_presentation.lua")
  local expectedA = (600 / 192) * zoomA
  local expectedB = (720 / 192) * zoomB
  Assert.near(scaleA, expectedA, 1e-9)
  Assert.near(scaleB, expectedB, 1e-9)
  -- Not simply proportional to host height: scaleB/scaleA != 720/600
  local hostRatio = 720 / 600
  local scaleRatio = scaleB / scaleA
  Assert.isTrue(
    math.abs(scaleRatio - hostRatio) > 0.01,
    "scale ratio must not equal host-height ratio when compensation active"
  )
end

function T.field_state_draw_sends_same_scale_to_both_renderers()
  local viewport = FieldViewport.new(1280, 600, { mode = "expanded" })
  local camera = { zoom = 1.25 }
  local expected = viewport:logicalPixelScale(camera.zoom)
  local fakeRuntimeMap = {
    mapId = 1,
    mapSymbol = "MAP_FAKE",
    sceneRuntime = { mapDraws = {}, staticBuildingDraws = {}, animatedBuildingDraws = {} },
  }
  local state = setmetatable({
    runtime = {
      viewport = viewport,
      camera = camera,
      runtimeMap = fakeRuntimeMap,
      player = { fieldX = 0, fieldZ = 0, worldY = 0, surfaceId = 0, facing = "south", motion = "idle" },
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
      dialogue = {
        isModal = function()
          return true
        end,
      },
      signpost = {
        isModal = function()
          return true
        end,
      },
      session = {
        renderAlpha = function()
          return 0
        end,
      },
      applicationHost = {
        status = function()
          return { fadeAlpha = 0 }
        end,
      },
      transition = { fadeAlpha = 0 },
      menuHost = {
        presentation = function()
          return nil
        end,
      },
      startMenuPlacement = nil,
      resizePresentation = function() end,
    },
    topologyProvider = function()
      local ScreenTopology = require("libs.engine.src.ScreenTopology")
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 1280, height = 600 },
        touch = false,
        role = "world",
      })
    end,
    renderer = { draw = function() end },
    worldParts = {},
    worldActorItems = {},
    spriteItems = {},
    _lastGeometrySignature = "1280:600:main:world:0:0:1280:600",
    _actorDrawStorage = { items = {}, actorSlots = {}, generation = 0 },
    _actorAssetLookup = function()
      error("no actor lookup")
    end,
  }, FieldState)
  state._worldParts = function()
    return {}
  end
  local gotDialogue, gotSignpost
  -- Current signature: dialogue:draw(controller, viewport), signpost:draw(controller, viewport, alpha)
  -- Future should be: dialogue:draw(controller, viewport, fieldScale), signpost:draw(controller, viewport, alpha, fieldScale)
  -- Capture any numeric that equals expected.
  ---@diagnostic disable-next-line: missing-fields
  state.dialogueRenderer = {
    draw = function(_, a, b, c)
      for _, v in ipairs({ a, b, c }) do
        if type(v) == "number" and math.abs(v - expected) < 1e-9 then
          gotDialogue = v
        end
      end
      if gotDialogue == nil and type(c) == "number" then
        gotDialogue = c
      end
    end,
  }
  ---@diagnostic disable-next-line: missing-fields
  state.signpostRenderer = {
    draw = function(_, a, b, c, d)
      for _, v in ipairs({ a, b, c, d }) do
        if type(v) == "number" and math.abs(v - expected) < 1e-9 then
          gotSignpost = v
        end
      end
      if gotSignpost == nil and type(d) == "number" then
        gotSignpost = d
      end
      if gotSignpost == nil and type(c) == "number" and c ~= 0 then
        gotSignpost = c
      end
    end,
  }
  local oldGetDimensions = love.graphics.getDimensions
  love.graphics.getDimensions = function()
    return 1280, 600
  end
  local FieldDrawState = require("libs.engine.src.FieldDrawState")
  local savedProtected = FieldDrawState.protectedDraw
  ---@diagnostic disable-next-line: duplicate-set-field
  FieldDrawState.protectedDraw = function(_, fn)
    fn()
  end
  local ok, err = pcall(function()
    state:draw()
  end)
  FieldDrawState.protectedDraw = savedProtected
  love.graphics.getDimensions = oldGetDimensions
  Assert.isTrue(ok, "FieldState draw should not throw: " .. tostring(err))
  Assert.notNil(
    gotDialogue,
    "dialogue renderer must receive field scale via viewport:logicalPixelScale(camera.zoom); got nil (layout ignores zoom)"
  )
  Assert.near(gotDialogue, expected, 1e-9)
  Assert.notNil(gotSignpost, "signpost renderer must receive same field scale; got nil")
  Assert.near(gotSignpost, expected, 1e-9)
end

return { tests = T }
