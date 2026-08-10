---@diagnostic disable: duplicate-set-field
-- LÖVE configuration for the game app. The test command (--test) runs
-- windowless and without GPU/audio so it is fast and headless; an ordinary boot
-- gets a normal resizable window. Headless detection is a plain scan of `arg`
-- because modules are not up yet.

local function isHeadless()
  for _, a in ipairs(arg or {}) do
    if a == "--test" then
      return true
    end
  end
  return false
end

function love.conf(t)
  t.identity = "g4recomp"
  t.version = "11.5"
  t.modules.physics = false

  if isHeadless() then
    t.modules.window = false
    t.modules.graphics = false
    t.modules.audio = false
    t.modules.sound = false
    t.modules.joystick = false
    t.modules.touch = false
  else
    t.window.title = "g4recomp"
    t.window.resizable = true
    t.window.vsync = 1
    t.window.depth = 24 -- 3D map rendering needs a depth buffer
    t.window.stencil = 8
    local width = tonumber(os.getenv("G4RECOMP_WINDOW_WIDTH") or "")
    local height = tonumber(os.getenv("G4RECOMP_WINDOW_HEIGHT") or "")
    if width then
      t.window.width = width
    end
    if height then
      t.window.height = height
    end
  end
end
