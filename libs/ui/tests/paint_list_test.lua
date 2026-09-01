-- PaintList stores only validated backend-neutral image and text commands.

local Assert = require("tests.support.Assert")

local T = {}

local function paintList()
  local ok, moduleOrError = pcall(require, "libs.ui.src.PaintList")
  Assert.isTrue(ok, "the reusable paint-list primitive must exist: " .. tostring(moduleOrError))
  return moduleOrError
end

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

function T.commands_preserve_order_and_are_backend_neutral()
  local PaintList = paintList()
  local list = PaintList.new()
  list:image("profile.male.backing", rect(10, 20, 30, 40))
  list:image("profile.male.focus", rect(10, 20, 30, 40), { r = 1, g = 0.5, b = 0, a = 1 })
  list:centeredText("YES", rect(12, 30, 26, 12), 2)

  local commands = list:commands()
  Assert.equal(#commands, 3)
  Assert.equal(commands[1].kind, "image")
  Assert.equal(commands[1].assetKey, "profile.male.backing")
  Assert.deepEqual(commands[1].rect, rect(10, 20, 30, 40))
  Assert.equal(commands[2].kind, "image")
  Assert.deepEqual(commands[2].tint, { r = 1, g = 0.5, b = 0, a = 1 })
  Assert.equal(commands[3].kind, "centeredText")
  Assert.equal(commands[3].text, "YES")
  Assert.deepEqual(commands[3].rect, rect(12, 30, 26, 12))
  Assert.equal(commands[3].scale, 2)
  Assert.isNil(commands[1].image)
  Assert.isNil(commands[1].loveObject)
end

function T.command_observations_cannot_mutate_the_stored_list()
  local PaintList = paintList()
  local list = PaintList.new()
  list:image("button.base", rect(1, 2, 3, 4), { r = 0.2, g = 0.3, b = 0.4, a = 0.5 })

  local observation = list:commands()
  observation[1].assetKey = "changed"
  observation[1].rect.x = 99
  observation[1].tint.r = 1
  observation[#observation + 1] = { kind = "image" }

  local unchanged = list:commands()
  Assert.equal(#unchanged, 1)
  Assert.equal(unchanged[1].assetKey, "button.base")
  Assert.deepEqual(unchanged[1].rect, rect(1, 2, 3, 4))
  Assert.deepEqual(unchanged[1].tint, { r = 0.2, g = 0.3, b = 0.4, a = 0.5 })
end

function T.commands_reject_invalid_keys_tints_rectangles_and_scales()
  local PaintList = paintList()
  local list = PaintList.new()
  local function rejects(fn)
    Assert.throws(fn)
  end

  rejects(function()
    list:image("", rect(0, 0, 1, 1))
  end)
  rejects(function()
    list:image(false, rect(0, 0, 1, 1))
  end)
  rejects(function()
    list:image("image", rect(0, 0, 0, 1))
  end)
  rejects(function()
    list:image("image", rect(0, 0, 1, 1), { r = 1, g = 0, b = 0, a = 2 })
  end)
  rejects(function()
    list:image("image", rect(0, 0, 1, 1), { r = 1, g = 0, b = nil, a = 1 })
  end)
  rejects(function()
    list:centeredText(4, rect(0, 0, 1, 1), 1)
  end)
  rejects(function()
    list:centeredText("YES", rect(0, 0, 1, 1), 0)
  end)
  rejects(function()
    list:centeredText("YES", rect(0, 0, math.huge, 1), 1)
  end)
  rejects(function()
    list:centeredText("YES", rect(0, 0, 1, 1), math.huge)
  end)
end

return { tests = T }
