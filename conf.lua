-- LÖVE configuration. Non-interactive invocations (--test, headless import,
-- dump audit) disable the window and GPU/audio modules so they run windowless
-- and fast; interactive boots get a normal resizable window. Headless detection
-- is a plain scan of `arg` here because modules are not up yet.

local function isHeadless()
  for _, a in ipairs(arg or {}) do
    if a == "--test" or a == "--test-private" or a == "--import-only"
      or a == "--check-dump" or a == "--inspect-map" or a == "--build-map" then
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
    t.window.depth = 24   -- 3D map rendering needs a depth buffer
    t.window.stencil = 8
  end
end
