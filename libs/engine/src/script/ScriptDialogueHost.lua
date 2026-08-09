-- Script dialogue host : the game-side bridge between the
-- script runtime's dialogue contract and the field dialogue controller. It
-- resolves message references (`msg.hgss.<bank>.<id>` through the message
-- provider, `msg.project.placeholder` to the project placeholder ellipsis),
-- formats substitution slots from the instance's buffered text arguments,
-- opens the controller as a script-owned request (the session's modal gate
-- skips script-owned boxes; the scheduler steps them through `advance`), and
-- reports typing progress from the controller's status. Pure domain module:
-- no love dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local FieldMessageText = require("libs.assets.src.FieldMessageText")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")

---@class ScriptDialogueHost
---@field private _controller table FieldDialogueController-shaped
---@field private _provider FieldMessageProvider
---@field private _layout fun(formatted: table): table
---@field private _fontDef table
---@field private _player table|nil
local ScriptDialogueHost = {}
ScriptDialogueHost.__index = ScriptDialogueHost

-- The project placeholder message: a short ellipsis box shown where a
-- translated script's unsupported commands were replaced by a dummy node.
ScriptDialogueHost.PLACEHOLDER_REF = "msg.project.placeholder"
ScriptDialogueHost.PLACEHOLDER_TEXT = "..."

-- STRVAR family bases; the low byte of a substitution control is its field
-- selector (the HGSS buffer value kind: 3 = player name, 0 = integer).
local STRVAR_BASE = 0x0100

-- Text-value descriptor resolvers for the slice: player name and integers.
-- Unresolved kinds leave the marker in the stream (visible, traced by the
-- formatter), matching the pre-script adapter's behavior.
---@param descriptor table
---@param player table
---@param fontDef table
---@return table|nil replacementTokens
local function resolveTextValue(descriptor, player, fontDef)
  if type(descriptor) ~= "table" or descriptor.text == nil then
    return nil
  end
  local kind = descriptor.text
  local value = descriptor.value
  if kind == "player_name" then
    return FieldMessageProvider.asciiGlyphTokens(player:name(), fontDef)
  elseif kind == "integer" then
    if value == nil or type(value) ~= "table" or value.value ~= "var" then
      return nil
    end
    local resolved = value.id
    if resolved == nil then
      return nil
    end
    return FieldMessageProvider.asciiGlyphTokens(tostring(resolved), fontDef)
  end
  return nil
end

---@param opts table { controller, provider, layout, fontDef, player }
---@return ScriptDialogueHost
function ScriptDialogueHost.new(opts)
  assert(
    type(opts) == "table" and opts.controller and opts.provider,
    "script dialogue host requires a controller and message provider"
  )
  assert(type(opts.layout) == "function", "script dialogue host requires the dialogue layout")
  assert(
    type(opts.fontDef) == "table" and type(opts.fontDef.charmap) == "table",
    "script dialogue host requires the generated font definition"
  )
  assert(opts.player and type(opts.player.name) == "function", "script dialogue host requires the player facade")
  return setmetatable({
    _controller = opts.controller,
    _provider = opts.provider,
    _layout = opts.layout,
    _fontDef = opts.fontDef,
    _player = opts.player,
  }, ScriptDialogueHost)
end

function ScriptDialogueHost:isOpen()
  return self._controller:isModal()
end

-- Resolve a message reference to a controller-ready formatted message.
---@param message any string reference or external descriptor
---@param bindings table slot -> text value
---@param textArgs table slot -> text value
---@return table formatted { tokens, ... }
function ScriptDialogueHost:resolveMessage(message, bindings, textArgs)
  if message == ScriptDialogueHost.PLACEHOLDER_REF then
    local tokens = FieldMessageText.parse(ScriptDialogueHost.PLACEHOLDER_TEXT, self._fontDef, { eos = false })
    return { tokens = tokens, text = ScriptDialogueHost.PLACEHOLDER_TEXT, hadUnresolvedSubstitutions = false }
  end
  if type(message) ~= "string" then
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "unsupported message reference form", { message = message })
  end
  local bankId, messageId = message:match("^msg%.hgss%.(%d+)%.(%d+)$")
  if bankId == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "unknown message reference " .. tostring(message),
      { message = message }
    )
  end
  bankId, messageId = tonumber(bankId), tonumber(messageId)
  local bank, bankErr = self._provider:acquireBank(bankId)
  if not bank then
    Errors.raise(
      bankErr and bankErr.code or "MESSAGE_BANK_MISSING",
      bankErr and bankErr.message or "message bank " .. tostring(bankId) .. " is unavailable",
      { bankId = bankId, cause = bankErr and bankErr.context or nil }
    )
  end
  local template, templateErr = self._provider:get(bankId, messageId)
  if not template then
    self._provider:releaseBank(bankId)
    Errors.raise(
      templateErr and templateErr.code or "MESSAGE_ID_OUT_OF_RANGE",
      templateErr and templateErr.message or "message " .. tostring(messageId) .. " not in bank " .. tostring(bankId),
      { bankId = bankId, messageId = messageId, cause = templateErr and templateErr.context or nil }
    )
  end
  -- One resolver per substitution control; the buffer slot is the marker's
  -- first argument. The node's own bindings win over instance textArgs.
  local resolvers = {}
  for _, token in ipairs(template.tokens) do
    if token.kind == "substitution" and token.args ~= nil then
      local slot = token.args[1]
      if slot ~= nil and resolvers[token.control] == nil then
        resolvers[token.control] = function(control, args, context)
          local descriptor = bindings[slot] or textArgs[slot]
          return resolveTextValue(descriptor, self._player, self._fontDef)
        end
      end
    end
  end
  local okFormat, formatted = pcall(self._provider.format, self._provider, template, {}, resolvers)
  self._provider:releaseBank(bankId)
  if not okFormat then
    error(formatted)
  end
  return formatted
end

-- Open: called with the graph node; the controller request
-- opens on the following startPrint so a failed resolve cannot leave a
-- half-open box.
---@param node table
function ScriptDialogueHost:openMessage(node)
  self._pendingNode = node
end

-- Open the controller as a script-owned request and start revealing.
---@param message any
---@param bindings table
---@param textArgs table
function ScriptDialogueHost:startPrint(message, bindings, textArgs)
  local node = self._pendingNode or {}
  self._pendingNode = nil
  local formatted = self:resolveMessage(message, bindings or {}, textArgs or {})
  local id = "script-dialogue"
  if node.message ~= nil then
    -- Stable per-node identity for diagnostics.
    id = "script-" .. tostring(node.message):gsub("%D+", "")
  end
  self._controller:open({
    id = id,
    message = formatted,
    style = "field",
    modal = true,
    allowCancel = false,
    metadata = {
      scriptOwned = true,
      message = message,
    },
  })
end

-- Typing progress for the dialogue task: page and glyph within the current
-- page, plus completion of the whole reveal (the controller reached its
-- final wait).
---@return table|nil { pageIndex, glyphIndex, done }
function ScriptDialogueHost:printProgress()
  if not self:isOpen() then
    return { pageIndex = 0, glyphIndex = 0, done = true }
  end
  local status = self._controller:status()
  local done = status.state == "WAITING_CLOSE" or status.state == "CLOSING" or status.state == "CLOSED"
  return {
    pageIndex = math.max(0, (status.pageIndex or 1) - 1),
    glyphIndex = status.revealedGlyphs or 0,
    done = done,
  }
end

-- Close the box (idempotent on the controller).
---@param erase boolean
function ScriptDialogueHost:close(erase)
  self._controller:close()
end

function ScriptDialogueHost:hold() end
function ScriptDialogueHost:showWaitingIcon() end
function ScriptDialogueHost:hideWaitingIcon() end

-- Advance an open script-owned box by one fixed tick. The scheduler calls
-- this from its engine-owned async phase with the immutable input snapshot;
-- the session's modal gate never steps script-owned requests.
---@param input table|nil
function ScriptDialogueHost:advance(input)
  if not self:isOpen() then
    return
  end
  input = input or {}
  self._controller:step({
    actionPressed = input.pressedAction == true,
    actionDown = input.actionDown == true,
    cancelPressed = input.pressedCancel == true,
    cancelDown = input.cancelDown == true,
  })
end

return ScriptDialogueHost
