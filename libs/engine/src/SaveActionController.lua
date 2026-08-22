-- Owns the non-interactive one-press Save application state. Capture is kept
-- separate from publication so an unstable field never reaches storage.
local SaveActionController = {}
SaveActionController.__index = SaveActionController

function SaveActionController.new(options)
  assert(type(options) == "table", "save controller options are required")
  assert(type(options.capture) == "function", "save capture is required")
  assert(type(options.publishFirst) == "function", "first publication is required")
  assert(type(options.update) == "function", "save update is required")
  return setmetatable({
    _capture = options.capture,
    _publishFirst = options.publishFirst,
    _update = options.update,
    _published = options.published == true,
    _state = "idle",
    _error = nil,
  }, SaveActionController)
end

function SaveActionController:activate()
  if self._state == "busy" then
    return "busy"
  end
  self._state = "busy"
  local ok, record, reason = pcall(self._capture)
  if not ok or record == nil then
    self._state = "error"
    self._error = ok and reason or record
    return "deferred"
  end
  local publishOk, publishError = pcall(function()
    if self._published then
      self._update(record)
    else
      self._publishFirst(record)
      self._published = true
    end
  end)
  if not publishOk then
    self._state = "error"
    self._error = publishError
    return "error"
  end
  return "busy"
end

function SaveActionController:finish()
  if self._state == "saved" then
    self._state = "idle"
  elseif self._state == "busy" then
    self._state = "saved"
  end
end

function SaveActionController:status()
  return { state = self._state, error = self._error }
end

function SaveActionController:updateFixed(_)
  if self._state == "idle" then
    self:activate()
  end
  if self._state == "busy" then
    self._state = "saved"
    self._result = { kind = "close" }
  end
end

function SaveActionController:takeResult()
  local result = self._result
  self._result = nil
  return result
end

function SaveActionController:dispose()
  self._state = "disposed"
end

return SaveActionController
