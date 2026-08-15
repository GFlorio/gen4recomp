-- The read-only Trainer Card viewer controller: it owns close input
-- only and has no access to Start Menu internals; a cancel edge returns
-- { kind = "close" } to the FieldApplicationHost exactly once. The close
-- input step exists in the source (ov51_021E6A54 in
-- asm/overlay_trainer_card_main.s at the pinned decomp commit plays
-- SEQ_SE_GS_GEARCANCEL for B and returns the close state), but this branch
-- does not reproduce the card's cancel effect: the controller requests no
-- sound. Every other input — directions, confirm, the synthesized menu edge,
-- and pointers — changes nothing: while a child application is active its
-- own input policy applies and the menu edge must not tear the card down.
-- The status passes the full model projection through unchanged
-- (name/gender/trainerId plus the explicit-nil optional fields), so the
-- renderer can choose the audited blank presentation for every value the
-- gameplay model does not own. Pure module: no love, no I/O, no Start Menu
-- internals.

---@class TrainerCardController
---@field _model table the model projection
---@field _result { kind: "close" }?
---@field _closed boolean
local TrainerCardController = {}
TrainerCardController.__index = TrainerCardController

---@param opts { model: table }
---@return TrainerCardController
function TrainerCardController.new(opts)
  assert(type(opts) == "table" and type(opts.model) == "table", "the trainer card controller requires the model")
  return setmetatable({
    _model = opts.model,
    _result = nil,
    _closed = false,
  }, TrainerCardController)
end

-- One fixed tick. The card consumes only its own close edge; foreign input
-- is ignored (the child-application input policy).
---@param uiInput table[]
function TrainerCardController:updateFixed(uiInput)
  assert(type(uiInput) == "table", "the trainer card input must be an event list")
  if self._closed then
    return
  end
  for _, event in ipairs(uiInput) do
    if not self._closed and type(event) == "table" and event.type == "cancel" then
      self:_close()
    end
  end
end

-- The close edge records the close state; the host owns the actual return
-- path.
function TrainerCardController:_close()
  self._result = { kind = "close" }
  self._closed = true
end

-- The presentation snapshot: the model projection passed through
-- unchanged, so the renderer never re-derives the player data. Fresh table
-- per call; the caller may not mutate controller state through it.
---@return table
function TrainerCardController:status()
  if self._closed then
    return { open = false }
  end
  local status = { open = true }
  for field, value in pairs(self._model) do
    status[field] = value
  end
  return status
end

-- The result contract: nil until a cancel edge, then exactly one
-- { kind = "close" }.
---@return { kind: "close" }?
function TrainerCardController:takeResult()
  local result = self._result
  self._result = nil
  if result ~= nil then
    self._closed = true
  end
  return result
end

-- Idempotent release of the logical lifetime: the host disposes the active
-- controller on success, cancellation, failure, reset, or runtime disposal.
-- A pending result is discarded (no close is reported after disposal).
function TrainerCardController:dispose()
  self._result = nil
  self._closed = true
end

return TrainerCardController
