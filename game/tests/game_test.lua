-- Component coverage for the generic running-game state host. The host owns
-- state replacement, event forwarding, settled drawable dimensions, and the
-- terminal exit/disposal contract without knowing HGSS or ROM concepts.

local Assert = require("tests.support.Assert")

local T = {}

local function loadGame()
  local ok, gameOrError = pcall(require, "game.src.Game")
  Assert.isTrue(
    ok,
    "the running-game lifecycle must provide game.src.Game independently of the launcher: " .. tostring(gameOrError)
  )
  Assert.isTrue(type(gameOrError.new) == "function", "the running-game lifecycle must expose Game.new")
  return gameOrError
end

local function disposableState()
  local state = { disposeCalls = 0, updateCalls = 0 }
  function state:dispose()
    self.disposeCalls = self.disposeCalls + 1
  end
  function state:update()
    self.updateCalls = self.updateCalls + 1
  end
  return state
end

function T.state_replacement_and_exit_dispose_each_owner_once()
  local Game = loadGame()
  local exits = {}
  local host = Game.new({
    onExit = function(result)
      exits[#exits + 1] = result
    end,
  })
  local first = disposableState()
  local second = disposableState()

  host:setState(first)
  host:setState(second)
  host:update(0)
  Assert.equal(first.disposeCalls, 1)
  Assert.equal(second.disposeCalls, 0)
  Assert.equal(first.updateCalls, 0)
  Assert.equal(second.updateCalls, 1)

  local result = { kind = "quit" }
  host:exit(result)
  host:exit({ kind = "repeat" })
  host:dispose()
  host:dispose()

  Assert.equal(second.disposeCalls, 1)
  Assert.deepEqual(exits, { result })
end

function T.callbacks_preserve_host_tuples_and_reconcile_settled_dimensions()
  local Game = loadGame()
  local graphics = love.graphics
  local originalGetDimensions = graphics.getDimensions
  local liveWidth, liveHeight = 800, 600
  local events = {}
  local joystick = {}
  local host
  local state = {
    resize = function(_, width, height)
      events[#events + 1] = { "resize", width, height }
    end,
    update = function()
      events[#events + 1] = { "update" }
    end,
    draw = function()
      events[#events + 1] = { "draw" }
    end,
    gamepadaxis = function(_, ...)
      events[#events + 1] = { "gamepadaxis", ... }
    end,
    mousepressed = function(_, ...)
      events[#events + 1] = { "mousepressed", ... }
    end,
    mousemoved = function(_, ...)
      events[#events + 1] = { "mousemoved", ... }
    end,
    mousereleased = function(_, ...)
      events[#events + 1] = { "mousereleased", ... }
    end,
    wheelmoved = function(_, ...)
      events[#events + 1] = { "wheelmoved", ... }
    end,
    touchpressed = function(_, ...)
      events[#events + 1] = { "touchpressed", ... }
    end,
    touchmoved = function(_, ...)
      events[#events + 1] = { "touchmoved", ... }
    end,
    touchreleased = function(_, ...)
      events[#events + 1] = { "touchreleased", ... }
    end,
  }
  graphics.getDimensions = function()
    return liveWidth, liveHeight
  end

  local ok, err = pcall(function()
    host = Game.new({ onExit = function() end })
    host:setState(state)
    host:resize(800, 600)
    host:update(0.016)

    host:gamepadaxis(joystick, "leftx", 0.75)
    host:mousepressed(12.5, 34.5, 1, true, 2)
    host:mousemoved(15.5, 36.5, 3, 2, false)
    host:mousereleased(15.5, 36.5, 1, true, 2)
    host:wheelmoved(2, -3)
    host:touchpressed("finger-1", 3.5, 4.5, 0.25, 0.5, 0.8)
    host:touchmoved("finger-1", 5.5, 6.5, 0.25, 0.5, 0.8)
    host:touchreleased("finger-1", 5.5, 6.5, 0.25, 0.5, 0.8)

    liveWidth, liveHeight = 900, 700
    host:update(0.016)
    liveWidth, liveHeight = 1024, 768
    host:draw()
    host:draw()
    host:dispose()
  end)
  graphics.getDimensions = originalGetDimensions
  if not ok then
    if host then
      pcall(host.dispose, host)
    end
    error(err, 0)
  end

  Assert.deepEqual(events, {
    { "resize", 800, 600 },
    { "update" },
    { "gamepadaxis", joystick, "leftx", 0.75 },
    { "mousepressed", 12.5, 34.5, 1, true, 2 },
    { "mousemoved", 15.5, 36.5, 3, 2, false },
    { "mousereleased", 15.5, 36.5, 1, true, 2 },
    { "wheelmoved", 2, -3 },
    { "touchpressed", "finger-1", 3.5, 4.5, 0.25, 0.5, 0.8 },
    { "touchmoved", "finger-1", 5.5, 6.5, 0.25, 0.5, 0.8 },
    { "touchreleased", "finger-1", 5.5, 6.5, 0.25, 0.5, 0.8 },
    { "resize", 900, 700 },
    { "update" },
    { "resize", 1024, 768 },
    { "draw" },
    { "draw" },
  })
end

return { tests = T }
