-- Script dialogue host : the game-side bridge between the
-- script runtime's dialogue contract and the field dialogue controller. It
-- resolves message references (`msg.hgss.<bank>.<id>` through the message
-- provider), formats substitution slots from the instance's buffered text
-- arguments, opens the controller as a script-owned request (the session's
-- modal gate skips script-owned boxes; the scheduler steps them through
-- `advance`), and reports typing progress from the controller's status.
-- Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local FieldMessageProvider = require("libs.engine.src.FieldMessageProvider")

---@class ScriptDialogueHost
---@field private _controller table FieldDialogueController-shaped
---@field private _provider FieldMessageProvider
---@field private _layout fun(formatted: table): table
---@field private _fontDef table
---@field private _player table|nil
---@field private _world table|nil world state { getVar(id) -> any }
---@field private _frameIndex integer|nil player-selected user-frame index, captured at open
---@field private _pendingNode table|nil
local ScriptDialogueHost = {}
ScriptDialogueHost.__index = ScriptDialogueHost

-- Text-value descriptor resolvers for the implemented forms: player name
-- and integers backed by a variable. Any other form is a fault: the
-- resolver contract never leaves a marker visible in the stream.
---@param descriptor table
---@param player table
---@param fontDef table
---@param world table|nil
---@return table|nil replacementTokens
local function resolveTextValue(descriptor, player, fontDef, world)
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
    if world == nil or world.getVar == nil then
      local context = { kind = kind, value = value }
      ---@cast context Errors.Context
      Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "integer text values require the world state", context)
    end
    local worldState = world --[[@as { getVar: fun(self: table, id: any): any }]]
    return FieldMessageProvider.asciiGlyphTokens(tostring(worldState:getVar(value.id)), fontDef)
  end
  Errors.raise(
    ScriptErrors.SCRIPT_UNSUPPORTED_REACHABLE,
    "unsupported buffered text form " .. tostring(kind),
    { kind = kind }
  )
end

---@param opts table { controller, provider, layout, fontDef, player, world, frameIndex? }
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
  local frameIndex = opts.frameIndex
  assert(
    frameIndex == nil or (type(frameIndex) == "number" and frameIndex >= 0 and frameIndex % 1 == 0),
    "script dialogue host frameIndex must be a non-negative integer"
  )
  return setmetatable({
    _controller = opts.controller,
    _provider = opts.provider,
    _layout = opts.layout,
    _fontDef = opts.fontDef,
    _player = opts.player,
    _world = opts.world,
    _frameIndex = frameIndex,
  }, ScriptDialogueHost)
end

function ScriptDialogueHost:isOpen()
  return self._controller:isModal()
end

-- Resolve a message reference to a controller-ready formatted message.
---@param message any string reference or external descriptor
---@param bindings table slot -> text value
---@param textArgs table slot -> text value
---@return FieldMessageProvider.FormattedMessage formatted { tokens, ... }
function ScriptDialogueHost:resolveMessage(message, bindings, textArgs)
  local bankId, messageId
  if type(message) == "string" then
    bankId, messageId = message:match("^msg%.hgss%.(%d+)%.(%d+)$")
    if bankId == nil then
      Errors.raise(
        ScriptErrors.SCRIPT_INVALID_REFERENCE,
        "unknown message reference " .. tostring(message),
        { message = message }
      )
    end
    bankId, messageId = tonumber(bankId), tonumber(messageId)
  elseif type(message) == "table" and message.message == "external" then
    bankId, messageId = message.bank, message.id
    if type(bankId) ~= "number" or bankId % 1 ~= 0 or type(messageId) ~= "number" or messageId % 1 ~= 0 then
      Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "external message location is invalid", { message = message })
    end
  else
    Errors.raise(ScriptErrors.SCRIPT_INVALID_REFERENCE, "unsupported message reference form", { message = message })
  end
  local bank, bankErr = self._provider:acquireBank(bankId)
  if not bank then
    local err = bankErr --[[@as Errors.Error]]
    local context = { bankId = bankId, cause = err.context }
    ---@cast context Errors.Context
    Errors.raise(err.code, err.message, context)
  end
  local template, templateErr = self._provider:get(bankId, messageId)
  if not template then
    self._provider:releaseBank(bankId)
    local err = templateErr --[[@as Errors.Error]]
    local context = { bankId = bankId, messageId = messageId, cause = err.context }
    ---@cast context Errors.Context
    Errors.raise(err.code, err.message, context)
  end
  -- One resolver per substitution control; the buffer slot is each marker's
  -- own first argument, so a control occurring at several slots resolves
  -- every occurrence from its own slot. The node's own bindings win over
  -- instance textArgs.
  local resolvers = {}
  local templateTokens = template --[[@as table]].tokens
  for _, token in ipairs(templateTokens) do
    if token.kind == "substitution" and token.args ~= nil and resolvers[token.control] == nil then
      resolvers[token.control] = function(_, args, _)
        local slot = args and args[1]
        local descriptor = bindings[slot] or textArgs[slot]
        return resolveTextValue(descriptor, self._player, self._fontDef, self._world)
      end
    end
  end
  local okFormat, formatted = pcall(self._provider.format, self._provider, template, {}, resolvers)
  self._provider:releaseBank(bankId)
  if not okFormat then
    error(formatted)
  end
  if formatted.hadUnresolvedSubstitutions then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "message " .. message .. " has unresolvable substitutions",
      { bankId = bankId, messageId = messageId }
    )
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
---@param bindings table|nil
---@param textArgs table|nil
function ScriptDialogueHost:startPrint(message, bindings, textArgs)
  local node = self._pendingNode or {}
  self._pendingNode = nil
  local formatted = self:resolveMessage(message, bindings or {}, textArgs or {})
  -- Stable per-node identity for diagnostics: the full reference string,
  -- never a digit run that could collide across banks.
  local id = "script-dialogue"
  if node.message ~= nil then
    id = "script-" .. tostring(node.message):gsub("[^%w]", "_")
  end
  self._controller:open({
    id = id,
    message = formatted,
    allowCancel = false,
    frameIndex = self._frameIndex,
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

-- Close the box (idempotent on the controller). A non-erasing close would
-- need a message buffer the controller does not own; requesting one is an
-- attributed fault rather than a silent ignore.
---@param erase boolean
function ScriptDialogueHost:close(erase)
  if erase == false then
    Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller cannot preserve a closed message box")
  end
  self._controller:close()
end

-- Message-hold and waiting-icon controls are part of the script dialogue
-- contract the controller does not implement; reaching them is an
-- attributed fault, never a silent no-op.
function ScriptDialogueHost:hold()
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller cannot hold a message")
end

function ScriptDialogueHost:showWaitingIcon()
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller has no waiting icon")
end

function ScriptDialogueHost:hideWaitingIcon()
  Errors.raise(ScriptErrors.SCRIPT_SERVICE_MISSING, "the dialogue controller has no waiting icon")
end

-- Advance an open script-owned box by one fixed tick. The scheduler calls
-- this from its engine-owned async phase with the immutable input snapshot;
-- the session's modal gate never steps script-owned requests.
---@param input table|nil
function ScriptDialogueHost:advance(input)
  if not self:isOpen() then
    return
  end
  input = input or {}
  local status = self._controller:status()
  -- DialogueTask owns the final confirm edge and performs the delayed close.
  -- Passing that edge to the controller would close it early, leaving the
  -- task blocked forever waiting for an edge that has already been consumed.
  local actionPressed = input.pressedAction == true and status.state ~= "WAITING_CLOSE"
  local cancelPressed = input.pressedCancel == true and status.state ~= "WAITING_CLOSE"
  self._controller:step({
    actionPressed = actionPressed,
    actionDown = input.actionDown == true,
    cancelPressed = cancelPressed,
    cancelDown = input.cancelDown == true,
  })
end

return ScriptDialogueHost
