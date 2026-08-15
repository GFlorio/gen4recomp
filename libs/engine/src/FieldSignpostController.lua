-- Pure fixed-tick signpost controller: the HGSS signpost command state
-- machine, wipe motion, and window printer. No love, no script runtime, no
-- I/O. Command timing follows Signpost_DoCurrentCommand (asm/signpost.s at
-- the pinned decomp commit, documented in docs/research/signpost-commands.md):
-- SHOW and HIDE finish on their own update; WIPE_IN/WIPE_OUT make exactly
-- three 16px motion updates and complete on the following endpoint-check
-- update. The controller stores the source appearance/type/map and the style
-- id but never resolves geometry, and it owns the active formatted message
-- and its printer state, captured when printing begins. It also owns the
-- wipe interpolation history (the offset captured at the start of each
-- update alongside the current one) so rendering can interpolate without
-- mutating any state, and the explicit operations the script runtime calls
-- outside the fixed-tick path: the instant fill, the semantic idle query,
-- and the immediate cleanup.

---@class FieldSignpostController
---@field _layout fun(message: FieldMessageProvider.FormattedMessage): { lines: { tokens: MessageToken[] }[] }
---@field _ticksPerGlyph integer
---@field _defaultStyleId string the construction style id setStyleId(nil) restores
---@field _styleId string
---@field _command "nop"|"show"|"wipe_out"|"wipe_in"|"hide"
---@field _previousOffset integer the offset captured at the start of the most recent updateFixed
---@field _offset integer
---@field _active boolean
---@field _sourceAppearance { game: string, type: integer, map: integer }?
---@field _print { lines: { tokens: MessageToken[] }[], revealed: integer, revealTicks: integer, total: integer, live: boolean }?
local FieldSignpostController = {}
FieldSignpostController.__index = FieldSignpostController

-- The five MAPSIGNCOMMAND_* values as the semantic command enum; numeric
-- source codes never appear at runtime.
FieldSignpostController.COMMANDS = {
  nop = true,
  show = true,
  wipe_out = true,
  wipe_in = true,
  hide = true,
}

FieldSignpostController.DEFAULT_TICKS_PER_GLYPH = 2
FieldSignpostController.DEFAULT_STYLE_ID = "hgss.signpost"

-- The hidden signpost BG layer position and the fixed 16px wipe step:
-- visible motion is exactly three logical steps.
local HIDDEN_OFFSET = -48
local WIPE_STEP = 16

local function glyphCount(lines)
  local count = 0
  for _, ln in ipairs(lines) do
    for _, token in ipairs(ln.tokens) do
      if token.kind == "glyph" then
        count = count + 1
      end
    end
  end
  return count
end

-- The token lines up to the Nth revealed glyph, with the same cut semantics
-- as the dialogue controller: non-glyph tokens before the cut are included
-- so markers show as soon as their position is reached; lines beyond the
-- cut are omitted.

---@param lines { tokens: MessageToken[] }[]
---@param revealed integer
---@return MessageToken[][]
local function visibleLines(lines, revealed)
  local out = {}
  local seen = 0
  for _, ln in ipairs(lines) do
    local tokens = {}
    for _, token in ipairs(ln.tokens) do
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

-- opts.layout(formattedMessage) -> { lines = { { tokens = MessageToken[] } } }
-- opts.ticksPerGlyph (default 2; FieldPlayerData.ticksPerGlyph supplies the
-- injected cadence), opts.styleId (default "hgss.signpost").

---@class FieldSignpostControllerOptions
---@field layout fun(message: FieldMessageProvider.FormattedMessage): { lines: { tokens: MessageToken[] }[] }
---@field ticksPerGlyph integer?
---@field styleId string?

---@param opts FieldSignpostControllerOptions
---@return FieldSignpostController
function FieldSignpostController.new(opts)
  assert(
    type(opts) == "table" and type(opts.layout) == "function",
    "FieldSignpostController requires a layout function"
  )
  local ticksPerGlyph = opts.ticksPerGlyph or FieldSignpostController.DEFAULT_TICKS_PER_GLYPH
  assert(ticksPerGlyph >= 1 and ticksPerGlyph % 1 == 0, "ticks per glyph must be a positive integer")
  local styleId = opts.styleId or FieldSignpostController.DEFAULT_STYLE_ID
  assert(type(styleId) == "string" and styleId ~= "", "style id must be a non-empty string")
  return setmetatable({
    _layout = opts.layout,
    _ticksPerGlyph = ticksPerGlyph,
    _defaultStyleId = styleId,
    _styleId = styleId,
    _command = "nop",
    _previousOffset = HIDDEN_OFFSET,
    _offset = HIDDEN_OFFSET,
    _active = false,
    _sourceAppearance = nil,
    _print = nil,
  }, FieldSignpostController)
end

-- The runtime equivalent of HGSS's field-text-box-open state: the signpost
-- window is presented (shown, sliding in, or sliding out).
---@return boolean
function FieldSignpostController:isModal()
  return self._active
end

-- The presentation snapshot: plain data only, freshly built per call, so
-- the renderer never mutates controller state through it.

---@class FieldSignpostController.Status
---@field active boolean window presented (isModal)
---@field command "nop"|"show"|"wipe_out"|"wipe_in"|"hide"
---@field previousLogicalYOffset integer stored BG offset captured at the start of the most recent updateFixed
---@field logicalYOffset integer stored signpost BG offset
---@field sourceAppearance { game: string, type: integer, map: integer }?
---@field styleId string
---@field visibleLines MessageToken[][]
---@field printDone boolean

---@return FieldSignpostController.Status
function FieldSignpostController:status()
  local print = self._print
  local appearance = self._sourceAppearance
  return {
    active = self._active,
    command = self._command,
    previousLogicalYOffset = self._previousOffset,
    logicalYOffset = self._offset,
    sourceAppearance = appearance and {
      game = appearance.game,
      type = appearance.type,
      map = appearance.map,
    } or nil,
    styleId = self._styleId,
    visibleLines = print and visibleLines(print.lines, print.revealed) or {},
    printDone = print ~= nil and print.revealed >= print.total,
  }
end

-- HGSS Signpost_SetCommand is a bare assignment with no busy guard: the
-- low-level signpost_command operation replaces the current command, and a
-- running wipe is superseded rather than rejected. Only updateFixed moves
-- the command back to nop after an action completes.

---@param command "nop"|"show"|"wipe_out"|"wipe_in"|"hide"
function FieldSignpostController:setCommand(command)
  assert(FieldSignpostController.COMMANDS[command] == true, "unknown signpost command " .. tostring(command))
  self._command = command
end

-- The semantic command-idle query: true exactly when no command is scheduled.
-- The "nop" spelling is the controller's own protocol; callers ask the
-- semantic question.
---@return boolean
function FieldSignpostController:isCommandIdle()
  return self._command == "nop"
end

-- Stores the script-provided source appearance (type/map) as presentation
-- data; the controller never resolves geometry. nil clears it. The values
-- are the raw source operands preserved by the importer.

---@param appearance { game: string, type: integer, map: integer }?
function FieldSignpostController:setSourceAppearance(appearance)
  if appearance == nil then
    self._sourceAppearance = nil
    return
  end
  assert(type(appearance) == "table", "source appearance must be a table")
  assert(appearance.game == "hgss", "source appearance game must be hgss")
  for _, field in ipairs({ "type", "map" }) do
    local value = appearance[field]
    assert(
      type(value) == "number" and value % 1 == 0 and value >= 0,
      "source appearance " .. field .. " must be a non-negative integer"
    )
  end
  self._sourceAppearance = {
    game = appearance.game,
    type = appearance.type,
    map = appearance.map,
  }
end

-- One field update: captures the current offset as the previous offset for
-- the renderer's interpolation pair, executes the current command, then
-- advances the active printer. SHOW and HIDE complete on this same update
-- (source cases 1 and 4 clear the command within the case; HIDE also resets
-- the stored BG offset to 0); wipes move one 16px step, hold the command on
-- the update that reaches the endpoint, and complete on the following
-- endpoint-check update.
function FieldSignpostController:updateFixed()
  self._previousOffset = self._offset
  local command = self._command
  if command == "show" then
    self._active = true
    self._offset = HIDDEN_OFFSET
    self._command = "nop"
  elseif command == "hide" then
    self:_resetPresentation()
  elseif command == "wipe_in" then
    if self._offset < 0 then
      self._offset = math.min(self._offset + WIPE_STEP, 0)
    else
      self._command = "nop"
    end
  elseif command == "wipe_out" then
    if self._offset > HIDDEN_OFFSET then
      self._offset = math.max(self._offset - WIPE_STEP, HIDDEN_OFFSET)
    else
      -- Endpoint observed: clear the tile area and reset the stored BG
      -- offset to 0. The cleared window must not flash at the reset
      -- position, so the snapshot no longer presents the window; the
      -- routed style ends with the presentation.
      self:_resetPresentation()
    end
  end
  self:_advancePrint()
end

-- The completed-hide presentation: window closed, printer cleared, command
-- idle, stored BG offset (and its history pair) at the presented rest 0,
-- routed style returned to the construction default. One authoritative
-- implementation shared by the hide update, the wipe-out endpoint check, and
-- the explicit cleanup operation.
function FieldSignpostController:_resetPresentation()
  self._active = false
  self._print = nil
  self._previousOffset = 0
  self._offset = 0
  self._command = "nop"
  self._styleId = self._defaultStyleId
end

-- Captures the message layout at print start. The layout's own error
-- propagates on failure, leaving the prior print and command state
-- untouched.

---@param message FieldMessageProvider.FormattedMessage
---@return { tokens: MessageToken[] }[]
function FieldSignpostController:_captureLines(message)
  assert(
    type(message) == "table" and type(message.tokens) == "table",
    "signpost print requires a formatted message with a token stream"
  )
  local result = self._layout(message)
  assert(type(result) == "table" and type(result.lines) == "table", "signpost layout must return a lines table")
  local lines = {}
  for _, ln in ipairs(result.lines) do
    assert(type(ln) == "table" and type(ln.tokens) == "table", "signpost layout lines must carry token arrays")
    lines[#lines + 1] = ln
  end
  return lines
end

-- Instant print: the whole message is complete immediately (opcode 55
-- prints instantly in the signpost window).

---@param message FieldMessageProvider.FormattedMessage
function FieldSignpostController:printInstant(message)
  local lines = self:_captureLines(message)
  local total = glyphCount(lines)
  self._print = { lines = lines, revealed = total, revealTicks = 0, total = total, live = false }
end

-- Typed print: glyphs reveal at the injected fixed-tick cadence (Trainer
-- Tips prints at the player's configured text speed; the controller does not
-- choose one); finishPrint fills the whole message on demand.

---@param message FieldMessageProvider.FormattedMessage
function FieldSignpostController:printTyped(message)
  local lines = self:_captureLines(message)
  local total = glyphCount(lines)
  self._print = { lines = lines, revealed = 0, revealTicks = 0, total = total, live = total > 0 }
end

-- The instant-fill operation (Trainer Tips A/B speed-up): a live typed
-- printer reveals the whole message immediately and stops advancing. The
-- window stays presented and every other presentation field is untouched;
-- without a print, or on an already-completed print, it is a no-op.
-- Idempotent.
function FieldSignpostController:finishPrint()
  local print = self._print
  if print == nil then
    return
  end
  print.revealed = print.total
  print.revealTicks = 0
  print.live = false
end

-- Explicit cleanup (script fault/cancellation teardown): returns the
-- controller to the completed-hide presentation on the call, without a
-- fixed-tick update from outside the scheduler. Idempotent.
function FieldSignpostController:hideImmediately()
  self:_resetPresentation()
end

-- Routes a script-requested window style id into the presentation (the
-- high-level S.sign / S.trainerTip path; the imported operations never set
-- it). The style lives only while the window is presented: the hide case
-- and the wipe-out endpoint check return it to the construction default, so
-- a high-level flow never leaks its style into a later flow.
---@param styleId string
function FieldSignpostController:setStyleId(styleId)
  assert(type(styleId) == "string" and styleId ~= "", "style id must be a non-empty string")
  self._styleId = styleId
end

-- Session teardown: returns the controller to its initial hidden state and
-- releases every owned surface (command, presentation, printer, appearance,
-- routed style) exactly once. Idempotent.
function FieldSignpostController:dispose()
  self._command = "nop"
  self._active = false
  self._previousOffset = HIDDEN_OFFSET
  self._offset = HIDDEN_OFFSET
  self._sourceAppearance = nil
  self._print = nil
  self._styleId = self._defaultStyleId
end

function FieldSignpostController:_advancePrint()
  local print = self._print
  if not print or not print.live or print.revealed >= print.total then
    return
  end
  print.revealTicks = print.revealTicks + 1
  -- revealTicks stays below ticksPerGlyph between updates, so at most one
  -- glyph reveals per update; revealed can never overshoot total.
  if print.revealTicks >= self._ticksPerGlyph then
    print.revealTicks = print.revealTicks - self._ticksPerGlyph
    print.revealed = print.revealed + 1
    if print.revealed >= print.total then
      print.live = false
    end
  end
end

return FieldSignpostController
