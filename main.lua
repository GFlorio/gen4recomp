-- Entry point. Parse flags once, then dispatch: `--test` runs the suite and
-- exits; everything else hands normalized options to App, which owns the
-- import/boot/runtime flow and any headless exit codes.

local Cli = require("src.app.Cli")

local App

function love.load(argv)
  local opts = Cli.parse(argv)

  if opts.test then
    local failures = require("tests.run").run()
    love.event.quit(failures == 0 and 0 or 1)
    return
  end

  if opts.testPrivate then
    local failures = require("tests.private.run").run()
    love.event.quit(failures == 0 and 0 or 1)
    return
  end

  App = require("src.app.App")
  App.load(opts)
end

function love.update(dt)
  if App then App.update(dt) end
end

function love.draw()
  if App then App.draw() end
end

function love.filedropped(file)
  if App then App.filedropped(file) end
end

function love.keypressed(key)
  if App then App.keypressed(key) end
end

function love.mousepressed(x, y, button)
  if App then App.mousepressed(x, y, button) end
end

function love.mousereleased(x, y, button)
  if App then App.mousereleased(x, y, button) end
end

function love.mousemoved(x, y, dx, dy)
  if App then App.mousemoved(x, y, dx, dy) end
end

function love.wheelmoved(x, y)
  if App then App.wheelmoved(x, y) end
end

function love.quit()
  if App then App.quit() end
end
