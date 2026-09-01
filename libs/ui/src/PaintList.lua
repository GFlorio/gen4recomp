-- Pure ordered backend-neutral image and centered-text paint commands.

local PaintList = {}
PaintList.__index = PaintList

local function finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function rectangle(value)
  assert(type(value) == "table", "paint rectangle is required")
  for _, field in ipairs({ "x", "y", "width", "height" }) do
    assert(finite(value[field]), "paint rectangle fields must be finite")
  end
  assert(value.width > 0 and value.height > 0, "paint rectangle must be positive")
  return { x = value.x, y = value.y, width = value.width, height = value.height }
end

local function tint(value)
  if value == nil then
    return nil
  end
  assert(type(value) == "table", "paint tint is invalid")
  local copy = {}
  for _, channel in ipairs({ "r", "g", "b", "a" }) do
    assert(finite(value[channel]) and value[channel] >= 0 and value[channel] <= 1, "paint tint is invalid")
    copy[channel] = value[channel]
  end
  return copy
end

local function copyCommand(command)
  local copy = { kind = command.kind }
  if command.kind == "image" then
    copy.assetKey = command.assetKey
    copy.rect = rectangle(command.rect)
    copy.tint = tint(command.tint)
  else
    copy.text = command.text
    copy.rect = rectangle(command.rect)
    copy.scale = command.scale
  end
  return copy
end

function PaintList.new()
  return setmetatable({ _commands = {} }, PaintList)
end

function PaintList:image(assetKey, destination, color)
  assert(type(assetKey) == "string" and assetKey ~= "", "paint image asset key must be non-empty")
  self._commands[#self._commands + 1] = {
    kind = "image",
    assetKey = assetKey,
    rect = rectangle(destination),
    tint = tint(color),
  }
end

function PaintList:centeredText(text, destination, scale)
  assert(type(text) == "string", "paint text must be a string")
  assert(finite(scale) and scale > 0, "paint text scale must be positive")
  self._commands[#self._commands + 1] = {
    kind = "centeredText",
    text = text,
    rect = rectangle(destination),
    scale = scale,
  }
end

function PaintList:commands()
  local result = {}
  for index, command in ipairs(self._commands) do
    result[index] = copyCommand(command)
  end
  return result
end

return PaintList
