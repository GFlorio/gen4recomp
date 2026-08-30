-- Production entrypoint input contract. The test loads the real LÖVE root and
-- records the arguments crossing from its callbacks into the real App module;
-- it does not reconstruct FieldState or provide a second input dispatcher.

---@diagnostic disable: duplicate-set-field -- the test restores these intentional App seams

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")

local T = {
  metadata = {
    tags = { "entrypoint", "input" },
  },
  tests = {},
}

local CALLBACKS = {
  "textinput",
  "gamepadaxis",
  "mousepressed",
  "mousemoved",
  "mousereleased",
  "wheelmoved",
  "touchpressed",
  "touchmoved",
  "touchreleased",
}

local function withEntrypoint(fn)
  local savedLoveCallbacks = {}
  for _, name in ipairs({ "load", unpack(CALLBACKS) }) do
    savedLoveCallbacks[name] = love[name]
  end

  local savedAppLoad = App.load
  local savedAppCallbacks = {}
  for _, name in ipairs(CALLBACKS) do
    savedAppCallbacks[name] = App[name]
  end

  local ok, err = xpcall(function()
    -- The entrypoint's real load path must require App before callbacks can
    -- reach it. Suppressing only App.load keeps this probe before booting a
    -- second field session; the App callback boundary remains production code.
    App.load = function() end
    local entrypoint = assert(loadfile(love.filesystem.getSourceBaseDirectory() .. "/game/main.lua"))
    entrypoint()
    love.load({})
    App.load = savedAppLoad

    local calls = {}
    for _, name in ipairs(CALLBACKS) do
      App[name] = function(...)
        calls[name] = { ... }
      end
    end
    fn(calls)
  end, debug.traceback)

  App.load = savedAppLoad
  for _, name in ipairs(CALLBACKS) do
    App[name] = savedAppCallbacks[name]
  end
  for _, name in ipairs({ "load", unpack(CALLBACKS) }) do
    love[name] = savedLoveCallbacks[name]
  end
  if not ok then
    error(err, 0)
  end
end

local function assertForwarded(calls, name, expected)
  Assert.equal(type(love[name]), "function", "love." .. name .. " must be registered by the entrypoint")
  calls[name] = nil
  love[name](unpack(expected))
  local actual = calls[name]
  Assert.notNil(actual, "love." .. name .. " must reach App." .. name)
  Assert.equal(#actual, #expected, "love." .. name .. " must preserve every LÖVE argument")
  for index, value in ipairs(expected) do
    Assert.equal(actual[index], value, "love." .. name .. " argument " .. index .. " changed")
  end
end

function T.tests.love_input_callbacks_reach_app_with_the_complete_argument_tuple()
  local joystick = {}
  local cases = {
    { "textinput", { "é" } },
    { "gamepadaxis", { joystick, "leftx", 0.75 } },
    { "mousepressed", { 12.5, 34.5, 1, true, 2 } },
    { "mousemoved", { 15.5, 36.5, 3, 2, false } },
    { "mousereleased", { 15.5, 36.5, 1, true, 2 } },
    { "wheelmoved", { 2, -3 } },
    { "touchpressed", { "finger-1", 3.5, 4.5, 0.25, 0.5, 0.8 } },
    { "touchmoved", { "finger-1", 5.5, 6.5, 0.25, 0.5, 0.8 } },
    { "touchreleased", { "finger-1", 5.5, 6.5, 0.25, 0.5, 0.8 } },
  }

  withEntrypoint(function(calls)
    for _, case in ipairs(cases) do
      assertForwarded(calls, case[1], case[2])
    end
  end)
end

return T
