-- Fixed-tick modal dialogue controller. Owns the
-- typewriter reveal state machine, Action reveal/advance/close semantics,
-- cancel policy, and the exactly-once completion handle. Layout and input are
-- injected, so headless tests drive the full lifecycle without LÖVE; the
-- controller never touches presentation. Pages come from the injected layout
-- function and stay immutable while the reveal cursor advances over them.

local Errors = require("libs.errors.src.Errors")

---@class FieldDialogueController
---@field _layout fun(message: FieldMessageProvider.FormattedMessage): DialogueLayout.Result
---@field _ticksPerGlyph integer
---@field _cursorBlinkTicks integer
---@field _state "CLOSED"|"OPENING"|"REVEALING"|"WAITING_BOUNDARY"|"WAITING_CLOSE"|"CLOSING"
---@field _request FieldDialogueController.Request?
---@field _handle FieldDialogueController.Handle?
---@field _pages DialogueLayout.Page[]?
---@field _pageGlyphs integer[]?
---@field _warnings DialogueLayout.Warning[]?
---@field _pageIndex integer
---@field _revealed integer
---@field _revealTicks integer
---@field _waitTicks integer
---@field _terminal { kind: string, result: FieldDialogueController.Result }?
---@field _pendingClose { kind: string, error: any }?
local FieldDialogueController = {}
FieldDialogueController.__index = FieldDialogueController

FieldDialogueController.DEFAULT_TICKS_PER_GLYPH = 2
FieldDialogueController.DEFAULT_CURSOR_BLINK_TICKS = 30

-- Pages whose breakKind asks the reader for Action ("prompt", "page") wait;
-- "line" and "overflow" auto-scroll into the next page the way the DS scrolls
-- a full box. "eos" waits for the final close.

---@param page DialogueLayout.Page
---@return boolean
local function waitsForAction(page)
  return page.breakKind == "prompt" or page.breakKind == "page" or page.breakKind == "eos"
end

---@param page DialogueLayout.Page
---@return integer
local function glyphCount(page)
  local count = 0
  for _, line in ipairs(page.lines) do
    for _, token in ipairs(line.tokens) do
      if token.kind == "glyph" then
        count = count + 1
      end
    end
  end
  return count
end

-- Flattens the page's tokens up to the Nth revealed glyph. Non-glyph tokens
-- before the cut are included so markers show as soon as their position is
-- reached; lines beyond the cut are omitted.

---@param page DialogueLayout.Page
---@param revealed integer
---@return MessageToken[][]
local function visibleLines(page, revealed)
  local out = {}
  local seen = 0
  for _, line in ipairs(page.lines) do
    local tokens = {}
    for _, token in ipairs(line.tokens) do
      if token.kind == "glyph" then
        if seen >= revealed then
          break
        end
        seen = seen + 1
      end
      tokens[#tokens + 1] = token
    end
    if #tokens > 0 then
      out[#out + 1] = tokens
    end
  end
  return out
end

-- opts.layout(formattedMessage) -> DialogueLayout.Result
-- opts.ticksPerGlyph (default 2), opts.cursorBlinkTicks (default 30).

---@class FieldDialogueControllerOptions
---@field layout fun(message: FieldMessageProvider.FormattedMessage): DialogueLayout.Result
---@field ticksPerGlyph integer?
---@field cursorBlinkTicks integer?

---@param opts FieldDialogueControllerOptions
---@return FieldDialogueController
function FieldDialogueController.new(opts)
  assert(
    type(opts) == "table" and type(opts.layout) == "function",
    "FieldDialogueController requires a layout function"
  )
  local ticksPerGlyph = opts.ticksPerGlyph or FieldDialogueController.DEFAULT_TICKS_PER_GLYPH
  assert(
    ticksPerGlyph >= 1 and ticksPerGlyph == math.floor(ticksPerGlyph),
    "ticks per glyph must be a positive integer"
  )
  local cursorBlinkTicks = opts.cursorBlinkTicks or FieldDialogueController.DEFAULT_CURSOR_BLINK_TICKS
  assert(
    cursorBlinkTicks >= 1 and cursorBlinkTicks == math.floor(cursorBlinkTicks),
    "cursor blink ticks must be a positive integer"
  )
  return setmetatable({
    _layout = opts.layout,
    _ticksPerGlyph = ticksPerGlyph,
    _cursorBlinkTicks = cursorBlinkTicks,
    _state = "CLOSED",
    _request = nil,
    _handle = nil,
    _pages = nil,
    _pageGlyphs = nil,
    _warnings = nil,
    _pageIndex = 0,
    _revealed = 0,
    _revealTicks = 0,
    _waitTicks = 0,
    _terminal = nil,
    _pendingClose = nil,
  }, FieldDialogueController)
end

---@return boolean
function FieldDialogueController:isModal()
  return self._state ~= "CLOSED"
end

-- True when the open request is owned by the field-script runtime (the
-- script dialogue host opens requests with `metadata.scriptOwned`). The
-- session's modal gate skips script-owned boxes: the script scheduler steps
-- them from its engine-owned async phase instead.
---@return boolean
function FieldDialogueController:isScriptOwned()
  if self._state == "CLOSED" or self._request == nil then
    return false
  end
  local metadata = self._request.metadata
  return metadata ~= nil and metadata.scriptOwned == true
end

---@return FieldDialogueController.Status
function FieldDialogueController:status()
  local page = self._pages and self._pages[self._pageIndex]
  local waiting = self._state == "WAITING_BOUNDARY" or self._state == "WAITING_CLOSE"
  local cursorOn = false
  if waiting then
    cursorOn = math.floor((self._waitTicks - 1) / self._cursorBlinkTicks) % 2 == 0
  end
  return {
    state = self._state,
    modal = self:isModal(),
    requestId = self._request and self._request.id or nil,
    bankId = self._request and self._request.message and self._request.message.bankId or nil,
    messageId = self._request and self._request.message and self._request.message.messageId or nil,
    pageIndex = self._pageIndex,
    pageCount = self._pages and #self._pages or 0,
    revealedGlyphs = self._revealed,
    pageGlyphCount = page and self._pageGlyphs[self._pageIndex] or 0,
    waiting = waiting,
    cursorOn = cursorOn,
    warnings = self._warnings or {},
    visibleLines = page and visibleLines(page, self._revealed) or {},
    allowCancel = self._request and self._request.allowCancel == true or false,
  }
end

-- Builds the terminal result: request identity plus any extra fields
-- (e.g. the layout error for the error path).

---@param kind string
---@param extra table?
---@return FieldDialogueController.Result
function FieldDialogueController:_result(kind, extra)
  local request = assert(self._request)
  local result = {
    kind = kind,
    requestId = request.id,
    bankId = request.message.bankId,
    messageId = request.message.messageId,
    metadata = request.metadata,
  }
  if extra then
    for key, value in pairs(extra) do
      result[key] = value
    end
  end
  return result
end

-- Queues a terminal and returns the result. The callback fires from
-- _dispatch, which runs only after the state machine finished mutating.

---@param kind string
---@param extra table?
---@return FieldDialogueController.Result
function FieldDialogueController:_complete(kind, extra)
  assert(not self._terminal, "dialogue already reached a terminal state")
  self._terminal = { kind = kind, result = self:_result(kind, extra) }
  return self._terminal.result
end

-- Fires the terminal callback exactly once, after every internal table is
-- fully settled, and returns the result. The request, handle, and page state
-- are released before the callback runs, so a callback that reopens a
-- dialogue (the reentrant-open contract) starts from a clean CLOSED
-- controller instead of inheriting the finished request; the terminal result
-- already carries the identity copies it needs.

---@return FieldDialogueController.Result?
function FieldDialogueController:_dispatch()
  local terminal = self._terminal
  if not terminal then
    return nil
  end
  self._terminal = nil
  local callback = terminal.kind == "complete" and self._handle._onComplete
    or terminal.kind == "cancel" and self._handle._onCancel
    or self._handle._onError
  self._request = nil
  self._handle = nil
  self._pages = nil
  self._pageGlyphs = nil
  self._warnings = nil
  local ok, err = pcall(function()
    if callback then
      callback(terminal.result)
    end
  end)
  if not ok then
    error(err)
  end
  return terminal.result
end

-- Opens a DialogueRequest (see Request for the shape). Returns the completion
-- handle. A malformed message (layout failure) still returns a handle whose
-- error callback fires exactly once; modal ownership engages for one tick so
-- the session's modal gate drives that dispatch, then releases.

---@param request FieldDialogueController.Request
---@return FieldDialogueController.Handle
function FieldDialogueController:open(request)
  assert(type(request) == "table" and type(request.id) == "string", "dialogue request requires an id")
  assert(
    type(request.message) == "table" and type(request.message.tokens) == "table",
    "dialogue request requires a formatted message with a token stream"
  )
  if self._state ~= "CLOSED" then
    Errors.raise(
      "DIALOGUE_ALREADY_OPEN",
      "a dialogue is already open; open() while modal is not allowed",
      { requestId = self._request and self._request.id }
    )
  end
  local handle = {}
  handle.onComplete = function(self, fn)
    self._onComplete = fn
    return self
  end
  handle.onCancel = function(self, fn)
    self._onCancel = fn
    return self
  end
  handle.onError = function(self, fn)
    self._onError = fn
    return self
  end
  local ok, pages = pcall(self._layout, request.message)
  self._request = request
  self._handle = handle
  self._pageIndex = 1
  self._revealed = 0
  self._revealTicks = 0
  self._waitTicks = 0
  self._terminal = nil
  self._pendingClose = nil
  if not ok then
    self._pages = {}
    self._pageGlyphs = {}
    self._warnings = {}
    self._state = "OPENING"
    self._pendingClose = { kind = "error", error = pages }
    return handle
  end
  local pageGlyphs = {}
  for index, page in ipairs(pages.pages) do
    pageGlyphs[index] = glyphCount(page)
  end
  self._pages = pages.pages
  self._pageGlyphs = pageGlyphs
  self._warnings = pages.warnings
  self._state = "OPENING"
  if #self._pages == 0 then
    -- An empty or control-only message closes safely on its first step: the
    -- session's modal gate still drives the completion, and handle callbacks
    -- registered after open() fire normally.
    self._pendingClose = { kind = "complete" }
  end
  return handle
end

-- Advances to the next page, or to the final wait when the last page ends.
-- Returns true when a page switch happened.

---@return boolean
function FieldDialogueController:_advancePage()
  if self._pageIndex >= #self._pages then
    self._state = "WAITING_CLOSE"
    return false
  end
  self._pageIndex = self._pageIndex + 1
  self._revealed = 0
  self._revealTicks = 0
  self._waitTicks = 0
  self._state = "REVEALING"
  return true
end

function FieldDialogueController:_enterWait()
  local page = self._pages[self._pageIndex]
  local state = page.breakKind == "eos" and "WAITING_CLOSE" or "WAITING_BOUNDARY"
  self._state = state
  self._waitTicks = 0
end

-- Called when the current page has fully revealed: prompt/page/eos pages
-- wait for Action; line/overflow pages auto-scroll into the next page.

function FieldDialogueController:_atPageEnd()
  local page = self._pages[self._pageIndex]
  if waitsForAction(page) then
    self:_enterWait()
    return
  end
  -- Auto-scroll (breakKind "line" or "overflow"); keep revealing on the next
  -- tick. Zero-glyph auto-scroll pages step through until a wait or a real
  -- reveal, bounded by the page count.
  while not waitsForAction(page) do
    if not self:_advancePage() then
      return
    end
    page = self._pages[self._pageIndex]
    if self._pageGlyphs[self._pageIndex] > 0 then
      return
    end
  end
  self:_enterWait()
end

---@param snapshot FieldDialogueController.Input
function FieldDialogueController:_revealTick(snapshot)
  local page = self._pages[self._pageIndex]
  local total = self._pageGlyphs[self._pageIndex]
  if snapshot.actionPressed then
    self._revealed = total
    self._revealTicks = 0
  else
    self._revealTicks = self._revealTicks + 1
    while self._revealTicks >= self._ticksPerGlyph do
      self._revealTicks = self._revealTicks - self._ticksPerGlyph
      self._revealed = self._revealed + 1
    end
    if self._revealed > total then
      self._revealed = total
    end
  end
  if self._revealed >= total then
    self:_atPageEnd()
  end
end

-- One fixed simulation tick. snapshot = { actionPressed, cancelPressed }
-- (the FieldInput snapshot edges this controller reads). Returns the
-- terminal result when this tick finished the dialogue, else nil.

---@param snapshot FieldDialogueController.Input?
---@return FieldDialogueController.Result?
function FieldDialogueController:step(snapshot)
  if self._state == "CLOSED" then
    return nil
  end
  snapshot = snapshot or {}

  if self._request.allowCancel and snapshot.cancelPressed and self._state ~= "CLOSING" then
    self._state = "CLOSED"
    self:_complete("cancel")
    return self:_dispatch()
  end

  if self._state == "OPENING" then
    if self._pendingClose then
      local pending = assert(self._pendingClose)
      self._pendingClose = nil
      self._state = "CLOSED"
      if pending.kind == "error" then
        self:_complete("error", { error = pending.error })
      else
        self:_complete("complete")
      end
      return self:_dispatch()
    end
    self._state = "REVEALING"
  end

  if self._state == "REVEALING" then
    self:_revealTick(snapshot)
  elseif self._state == "WAITING_BOUNDARY" or self._state == "WAITING_CLOSE" then
    self._waitTicks = self._waitTicks + 1
    if snapshot.actionPressed then
      if self._state == "WAITING_BOUNDARY" then
        self:_advancePage()
      else
        self._state = "CLOSING"
      end
    end
  elseif self._state == "CLOSING" then
    self._state = "CLOSED"
    self:_complete("complete")
    return self:_dispatch()
  end

  return nil
end

-- Closes an open dialogue with a completion result. Idempotent: a second
-- close on a closed controller returns nil and fires nothing.

---@return FieldDialogueController.Result?
function FieldDialogueController:close()
  if self._state == "CLOSED" then
    return nil
  end
  if self._state ~= "CLOSING" then
    self._state = "CLOSING"
  end
  self._state = "CLOSED"
  self:_complete("complete")
  return self:_dispatch()
end

-- State disposal: cancels an open dialogue exactly once and never re-enters
-- modal ownership. Used on map teardown and quit paths.

---@return FieldDialogueController.Result?
function FieldDialogueController:dispose()
  if self._state == "CLOSED" then
    return nil
  end
  self._state = "CLOSED"
  self:_complete("cancel")
  return self:_dispatch()
end

-- A DialogueRequest is the immutable open() argument.
-- The message is a formatted, pre-layout message; the pre-script adapter
-- builds it from the message provider.

---@class FieldDialogueController.Request
---@field id string
---@field message FieldMessageProvider.FormattedMessage
---@field allowCancel boolean
---@field metadata table?

-- The completion handle: exactly one of onComplete/onCancel/onError fires,
-- once, after the dialogue settles. Register handlers right after open().

---@class FieldDialogueController.Handle
---@field _onComplete fun(result: FieldDialogueController.Result)?
---@field _onCancel fun(result: FieldDialogueController.Result)?
---@field _onError fun(result: FieldDialogueController.Result)?
---@field onComplete fun(self: FieldDialogueController.Handle, fn: fun(result: FieldDialogueController.Result)): FieldDialogueController.Handle
---@field onCancel fun(self: FieldDialogueController.Handle, fn: fun(result: FieldDialogueController.Result)): FieldDialogueController.Handle
---@field onError fun(self: FieldDialogueController.Handle, fn: fun(result: FieldDialogueController.Result)): FieldDialogueController.Handle

-- The terminal result delivered to callbacks and returned by step/close/
-- dispose when they finish the dialogue.

---@class FieldDialogueController.Result
---@field kind "complete"|"cancel"|"error"
---@field requestId string
---@field bankId integer?
---@field messageId integer?
---@field metadata table?
---@field error any?

-- Fixed-tick input snapshot consumed by step(); produced by FieldInput.

---@class FieldDialogueController.Input
---@field actionPressed boolean?
---@field cancelPressed boolean?

-- Snapshot of the controller's reveal position for the renderer and HUD.

---@class FieldDialogueController.Status
---@field state "CLOSED"|"OPENING"|"REVEALING"|"WAITING_BOUNDARY"|"WAITING_CLOSE"|"CLOSING"
---@field modal boolean
---@field requestId string?
---@field bankId integer?
---@field messageId integer?
---@field pageIndex integer
---@field pageCount integer
---@field revealedGlyphs integer
---@field pageGlyphCount integer
---@field waiting boolean
---@field cursorOn boolean
---@field warnings DialogueLayout.Warning[]
---@field visibleLines MessageToken[][]
---@field allowCancel boolean

return FieldDialogueController
