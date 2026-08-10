-- The test host itself. The test command used to disable the window and
-- graphics modules, so every renderer test returned early and was counted as a
-- pass. The suite now runs against a real offscreen context: graphics, window,
-- and image are up, the true host boundaries the tests do not need stay down,
-- and the runner's own capability detection agrees with what this process can
-- actually do.

local Assert = require("tests.support.Assert")
local Capabilities = require("tests.runner.Capabilities")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")

local T = {}

function T.the_test_host_has_graphics_window_and_image_modules()
  Assert.notNil(love.graphics, "the test command must keep love.graphics")
  Assert.notNil(love.window, "the test command must keep love.window")
  Assert.notNil(love.image, "the test command must keep love.image")
  Assert.isTrue(love.window.isOpen(), "graphics need an open window")
end

function T.the_test_window_is_offscreen_and_free_of_vsync()
  Assert.notNil(love.window, "the test command must keep love.window")
  Assert.notNil(love.graphics, "the test command must keep love.graphics")
  Assert.equal(love.window.getVSync(), 0, "a vsync-paced test window would throttle the suite")
  Assert.isTrue(love.graphics.getWidth() > 0 and love.graphics.getHeight() > 0, "the test window has no drawable area")
end

function T.audio_and_input_host_modules_stay_disabled()
  for _, name in ipairs({ "audio", "sound", "joystick", "touch", "physics" }) do
    Assert.isNil(love[name], "the test command must keep love." .. name .. " disabled")
  end
end

-- The preflight is what lets a graphics suite skip honestly elsewhere. Here it
-- must succeed: this environment supports the suite, so a missing capability is
-- an infrastructure failure, not a reason to skip.
function T.the_runner_detects_the_graphics_capability_on_this_host()
  local capabilities = Capabilities.detect({ versions = {}, env = {} })

  Assert.isTrue(capabilities.graphics, "the graphics preflight failed on a host that has love.graphics")
end

return GraphicsSmoke.suite(T)
