-- Formats live test progress without reporting failure details before the
-- completed-run report. Every tenth passing test emits one dot; skips and
-- failures emit colored markers in the same stream, wrapping at 120 symbols.

local Progress = {}
Progress.__index = Progress
local RED = "\27[31m"
local YELLOW = "\27[33m"
local RESET = "\27[0m"
local LINE_WIDTH = 120

---@param write fun(text: string)
---@return table progress
function Progress.new(write)
  assert(type(write) == "function", "progress output needs a writer")
  return setmetatable({ write = write, passed = 0, lineLength = 0 }, Progress)
end

---@param result { status: string }
function Progress:record(result)
  local marker
  if result.status == "pass" then
    self.passed = self.passed + 1
    if self.passed % 10 == 0 then
      marker = "."
    end
  elseif result.status == "skip" then
    marker = YELLOW .. "S" .. RESET
  elseif result.status == "fail" then
    marker = RED .. "F" .. RESET
  end

  if marker == nil then
    return
  end
  if self.lineLength == LINE_WIDTH then
    self.write("\n")
    self.lineLength = 0
  end
  self.write(marker)
  self.lineLength = self.lineLength + 1
end

function Progress:finish()
  if self.lineLength > 0 then
    self.write("\n")
    self.lineLength = 0
  end
end

return Progress
