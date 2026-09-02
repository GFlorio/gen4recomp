-- App entry point. This app is its own LÖVE root (`love app/`); the repo root
-- (the source base directory) is added to package.path first so `require`
-- resolves libs and sibling apps by their full repo-relative path (libs.*,
-- game.src.*, data.*) independent of the working directory. Flags: --test runs
-- the recursively discovered, layer-selectable test suite and exits; --actors
-- opens the compiled field-actor preview
-- grid; --dev enables the playtest HUD and the F1/F2 developer binds; without
-- it the app runs in product mode; otherwise App drives the normal
-- boot/import/Main Menu flow. Options.parse owns strictness: unknown options and
-- stray arguments are rejected with a message on
-- stderr and exit status 2, and everything after the exact --test token is
-- left to the test command.
local ROOT = love.filesystem.getSourceBaseDirectory()
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

local Options = require("app.src.Options")

local App

---@diagnostic disable-next-line: duplicate-set-field
function love.load(argv)
  local opts, message = Options.parse(argv)
  if opts == nil then
    -- A raise from love.load would hang headless on the error screen; reject
    -- with the usage status instead. "app: " mirrors the test command's
    -- "test: " prefix.
    io.stderr:write("app: " .. message .. "\n")
    love.event.quit(Options.EXIT_USAGE)
    return
  end

  if opts.test then
    -- The test command owns its own argument parsing and exit status.
    love.event.quit(require("tests.run").main(argv))
    return
  end

  App = require("app.src.App")
  App.load(opts)
end

---@diagnostic disable-next-line: duplicate-set-field
function love.update(dt)
  if App then
    App.update(dt)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.draw()
  if App then
    App.draw()
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.resize(width, height)
  if App then
    App.resize(width, height)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.filedropped(file)
  if App then
    App.filedropped(file)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.keypressed(key, scancode, isrepeat)
  if App then
    App.keypressed(key, scancode, isrepeat)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.textinput(text)
  if App then
    App.textinput(text)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.keyreleased(key, scancode)
  if App then
    App.keyreleased(key, scancode)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.gamepadpressed(joystick, button)
  if App then
    App.gamepadpressed(joystick, button)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.gamepadreleased(joystick, button)
  if App then
    App.gamepadreleased(joystick, button)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.gamepadaxis(joystick, axis, value)
  if App then
    App.gamepadaxis(joystick, axis, value)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.mousepressed(x, y, button, istouch, presses)
  if App then
    App.mousepressed(x, y, button, istouch, presses)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.mousemoved(x, y, dx, dy, istouch)
  if App then
    App.mousemoved(x, y, dx, dy, istouch)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.mousereleased(x, y, button, istouch, presses)
  if App then
    App.mousereleased(x, y, button, istouch, presses)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.wheelmoved(x, y)
  if App then
    App.wheelmoved(x, y)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.touchpressed(id, x, y, dx, dy, pressure)
  if App then
    App.touchpressed(id, x, y, dx, dy, pressure)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.touchmoved(id, x, y, dx, dy, pressure)
  if App then
    App.touchmoved(id, x, y, dx, dy, pressure)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.touchreleased(id, x, y, dx, dy, pressure)
  if App then
    App.touchreleased(id, x, y, dx, dy, pressure)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.focus(focused)
  if App then
    App.focus(focused)
  end
end

---@diagnostic disable-next-line: duplicate-set-field
function love.quit()
  if App then
    App.quit()
  end
end
