local Assert = require("tests.support.Assert")
local SaveActionController = require("libs.engine.src.SaveActionController")

local T = { tests = {} }

local function snapshot()
  return { saveId = "save-00000001" }
end

function T.tests.one_press_publishes_without_confirmation_and_busy_blocks_repeat()
  local calls = {}
  local controller = SaveActionController.new({
    saveId = "save-00000001",
    capture = function()
      calls[#calls + 1] = "capture"
      return snapshot()
    end,
    publishFirst = function()
      calls[#calls + 1] = "publishFirst"
    end,
    update = function()
      calls[#calls + 1] = "update"
    end,
  })
  Assert.equal(controller:activate(), "busy")
  Assert.equal(controller:activate(), "busy")
  Assert.deepEqual(calls, { "capture", "publishFirst" })
  controller:finish()
  Assert.equal(controller:status().state, "saved")
end

function T.tests.first_application_tick_captures_and_publishes()
  local calls = {}
  local controller = SaveActionController.new({
    capture = function()
      calls[#calls + 1] = "capture"
      return snapshot()
    end,
    publishFirst = function()
      calls[#calls + 1] = "publishFirst"
    end,
    update = function() end,
  })
  controller:updateFixed({})
  Assert.deepEqual(calls, { "capture", "publishFirst" })
  Assert.deepEqual(controller:takeResult(), { kind = "close" })
end

function T.tests.capture_failure_never_publishes()
  local published = false
  local controller = SaveActionController.new({
    saveId = "save-00000001",
    capture = function()
      return nil, "deferred"
    end,
    publishFirst = function()
      published = true
    end,
    update = function() end,
  })
  Assert.equal(controller:activate(), "deferred")
  Assert.isFalse(published)
  Assert.equal(controller:status().state, "error")
end

return T
