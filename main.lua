-- Entry point (spec §15.3). Parse flags + env once, then dispatch: `--test` runs
-- the suite and exits; everything else hands normalized options to App, which
-- owns the import/boot/runtime flow and any headless exit codes.

local Cli = require("src.app.Cli")

local App

function love.load(argv)
  local opts = Cli.parse(argv, function(name) return os.getenv(name) end)

  if opts.test then
    local failures = require("tests.run").run()
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
