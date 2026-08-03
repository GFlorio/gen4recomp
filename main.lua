-- Entry point. `--test` runs the suite and exits; otherwise control passes to
-- App. Full flag parsing and import/boot orchestration (spec §15.3) land in a
-- later epic.

local function hasFlag(args, name)
  for _, a in ipairs(args or {}) do
    if a == name then return true end
  end
  return false
end

local App

function love.load(args)
  if hasFlag(args, "--test") then
    local failures = require("tests.run").run()
    love.event.quit(failures == 0 and 0 or 1)
    return
  end

  App = require("src.app.App")
  App.load(args)
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
