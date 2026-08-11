-- The development gate over the playtest presentation. Product mode (the
-- default) renders no playtest HUD and ignores the F1 save / F2 reset
-- developer binds; dev mode keeps both. The zoom keys are documented product
-- camera controls (docs/field-camera.md) and must survive the gate.

local Assert = require("tests.support.Assert")
local FieldState = require("game.src.game.FieldState")

local T = {}

-- A bare FieldState (no boot) shaped like a live presentation state: the
-- canonical runtime fields the draw path touches, a stubbed renderer, and the
-- development flag under test. The player visual record is invisible, so the
-- actor assembly never touches the presentation asset provider.
local function drawableState(development)
  return setmetatable({
    development = development == true,
    runtime = {
      runtimeMap = {
        mapId = 61,
        mapSymbol = "MAP_NEW_BARK",
        sceneRuntime = { mapDraws = {}, buildingDraws = {} },
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
      viewport = { width = 640, height = 480, worldViewport = { x = 0, y = 0, width = 640, height = 480 } },
      mapLoader = { updateCoverage = function() end },
      camera = {},
    },
    renderer = { draw = function() end },
  }, FieldState)
end

-- Counts the HUD's graphics calls through the real offscreen graphics host,
-- restoring print/rectangle on every path.
local function withHudGraphicsSpy(fn)
  local graphics = love.graphics
  local counts = { print = 0, rectangle = 0 }
  local original = {}
  for name in pairs(counts) do
    original[name] = graphics[name]
    graphics[name] = function()
      counts[name] = counts[name] + 1
    end
  end
  local ok, err = pcall(fn)
  for name in pairs(original) do
    graphics[name] = original[name]
  end
  if not ok then
    error(err, 0)
  end
  return counts
end

-- DEV-01: product mode (the default) renders no playtest HUD.
function T.product_mode_draw_renders_no_playtest_hud()
  local counts = withHudGraphicsSpy(function()
    drawableState(false):draw()
  end)
  Assert.equal(counts.print, 0, "product mode must not print the playtest HUD")
  Assert.equal(counts.rectangle, 0, "product mode must not draw the HUD backdrop")
end

-- DEV-02: dev mode keeps the playtest HUD exactly as today.
function T.dev_mode_draw_keeps_the_playtest_hud()
  local counts = withHudGraphicsSpy(function()
    drawableState(true):draw()
  end)
  Assert.equal(counts.print, 4, "dev mode keeps the four playtest HUD lines")
  Assert.equal(counts.rectangle, 1, "dev mode keeps the HUD backdrop")
end

-- DEV-03: product mode ignores the F1 save / F2 reset developer binds.
function T.product_mode_ignores_the_f1_and_f2_developer_binds()
  local saves, resets = 0, 0
  local state = setmetatable({
    runtime = {},
    _save = function()
      saves = saves + 1
    end,
    _reset = function()
      resets = resets + 1
    end,
  }, FieldState)
  state:keypressed("f1")
  state:keypressed("f2")
  Assert.equal(saves, 0, "product mode must ignore the F1 developer save bind")
  Assert.equal(resets, 0, "product mode must ignore the F2 developer reset bind")
end

-- DEV-04: dev mode keeps the F1 save / F2 reset binds.
function T.dev_mode_keeps_the_f1_and_f2_developer_binds()
  local saves, resets = 0, 0
  local state = setmetatable({
    development = true,
    runtime = {},
    _save = function()
      saves = saves + 1
    end,
    _reset = function()
      resets = resets + 1
    end,
  }, FieldState)
  state:keypressed("f1")
  state:keypressed("f2")
  Assert.equal(saves, 1, "dev mode keeps the F1 save bind")
  Assert.equal(resets, 1, "dev mode keeps the F2 reset bind")
end

-- DEV-05: the zoom keys are documented product camera controls
-- (docs/field-camera.md "Configurable zoom") and must survive the gate.
function T.product_mode_keeps_the_documented_zoom_controls()
  local zooms = {}
  local changes = 0
  local state = setmetatable({
    zoom = {
      zoomOut = function()
        zooms[#zooms + 1] = "out"
      end,
      zoomIn = function()
        zooms[#zooms + 1] = "in"
      end,
      reset = function()
        zooms[#zooms + 1] = "reset"
      end,
    },
    _applyZoomChange = function()
      changes = changes + 1
    end,
  }, FieldState)
  state:keypressed("-")
  state:keypressed("=")
  state:keypressed("0")
  Assert.deepEqual(zooms, { "out", "in", "reset" }, "zoom keys are product controls, not gated")
  Assert.equal(changes, 3, "each zoom key reapplies the camera projection")
end

return T
