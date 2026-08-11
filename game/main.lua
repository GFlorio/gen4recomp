---@diagnostic disable: duplicate-set-field
-- Game entry point. This app is its own LÖVE root (`love game/`); the repo root
-- (the source base directory) is added to package.path first so `require`
-- resolves libs and sibling apps by their full repo-relative path (libs.*,
-- game.src.*, data.*) independent of the working directory. Flags: --test runs
-- the recursively discovered, layer-selectable test suite and exits; --field
-- boots a fixed field target; --actors opens the compiled field-actor preview
-- grid; --dev enables the playtest HUD and the F1/F2 developer binds; without
-- it the app runs in product mode; --new-field-session
-- clears the selected version's project save; otherwise App drives the normal
-- boot/import flow.
local ROOT = love.filesystem.getSourceBaseDirectory()
package.path = ROOT .. "/?.lua;" .. ROOT .. "/?/init.lua;" .. package.path

local function parse(argv)
  local opts = { test = false, field = nil, actors = false, newFieldSession = false, dev = false }
  local i = 1
  while i <= #(argv or {}) do
    local option = argv[i]
    if option == "--test" then
      opts.test = true
    elseif option == "--field" then
      opts.field = true
      if argv[i + 1] and argv[i + 1]:sub(1, 2) ~= "--" then
        i = i + 1
        opts.field = argv[i]
      end
    elseif option == "--actors" then
      opts.actors = true
    elseif option == "--dev" then
      opts.dev = true
    elseif option == "--new-field-session" then
      opts.newFieldSession = true
    end
    i = i + 1
  end
  return opts
end

local App

function love.load(argv)
  local opts = parse(argv)

  if opts.test then
    -- The test command owns its own argument parsing and exit status.
    love.event.quit(require("tests.run").main(argv))
    return
  end

  App = require("game.src.game.App")
  App.load(opts)
end

function love.update(dt)
  if App then
    App.update(dt)
  end
end

function love.draw()
  if App then
    App.draw()
  end
end

function love.filedropped(file)
  if App then
    App.filedropped(file)
  end
end

function love.keypressed(key, scancode, isrepeat)
  if App then
    App.keypressed(key, scancode, isrepeat)
  end
end

function love.keyreleased(key, scancode)
  if App then
    App.keyreleased(key, scancode)
  end
end

function love.gamepadpressed(joystick, button)
  if App then
    App.gamepadpressed(joystick, button)
  end
end

function love.gamepadreleased(joystick, button)
  if App then
    App.gamepadreleased(joystick, button)
  end
end

function love.focus(focused)
  if App then
    App.focus(focused)
  end
end

function love.quit()
  if App then
    App.quit()
  end
end
