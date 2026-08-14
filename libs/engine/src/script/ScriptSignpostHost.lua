-- Script signpost host : the game-side bridge between the script
-- runtime's signpost operations and the field signpost controller. It
-- resolves message references through the injected public message-resolution
-- operation (ScriptDialogueHost:resolveMessage, never an underscored helper
-- or duplicated substitution semantics), forwards configuration and
-- window/printer requests to the controller, and advances the controller
-- once per scheduler tick from the engine-owned async phase. The host never
-- writes world variables: variable writes stay authoritative in
-- Runtime.writeRef via task results. Pure domain module: no love dependency.

---@class ScriptSignpostHost
---@field private _controller FieldSignpostController
---@field private _resolveMessage fun(message: any, bindings: table, textArgs: table): table
local ScriptSignpostHost = {}
ScriptSignpostHost.__index = ScriptSignpostHost

---@param opts table { controller, resolveMessage }
---@return ScriptSignpostHost
function ScriptSignpostHost.new(opts)
  assert(
    type(opts) == "table" and opts.controller and opts.controller.isModal,
    "script signpost host requires the signpost controller"
  )
  assert(type(opts.resolveMessage) == "function", "script signpost host requires the message-resolution operation")
  return setmetatable({
    _controller = opts.controller,
    _resolveMessage = opts.resolveMessage,
  }, ScriptSignpostHost)
end

-- The runtime equivalent of HGSS's field-text-box-open state comes straight
-- from the controller: one ownership source, no second boolean that could
-- disagree with it.
---@return boolean
function ScriptSignpostHost:isModal()
  return self._controller:isModal()
end

-- Window request: the semantic command assignment (nop/show/wipe_out/
-- wipe_in/hide). Presentation-neutral passthrough; the controller owns the
-- command state machine.
---@param command "nop"|"show"|"wipe_out"|"wipe_in"|"hide"
function ScriptSignpostHost:setCommand(command)
  self._controller:setCommand(command)
end

-- Signpost configuration: the source appearance (game/type/map) is stored as
-- presentation data. The host never resolves geometry.
---@param appearance { game: string, type: integer, map: integer }?
function ScriptSignpostHost:setSourceAppearance(appearance)
  self._controller:setSourceAppearance(appearance)
end

-- Style routing for the high-level sign operations: the script-requested
-- window style id (a registered id or a semantic appearance already resolved
-- by the runtime) is stamped into the controller's presentation. The host
-- never resolves geometry from it.
---@param styleId string
function ScriptSignpostHost:setStyleId(styleId)
  self._controller:setStyleId(styleId)
end

-- Print the whole message instantly in the signpost window (the immediate
-- direction-signpost path): resolve and expand, then print. The request is
-- presentation-neutral; text colors are the style's, never the host's.
---@param message any
---@param bindings table|nil
---@param textArgs table|nil
function ScriptSignpostHost:printInstant(message, bindings, textArgs)
  local formatted = self._resolveMessage(message, bindings or {}, textArgs or {})
  self._controller:printInstant(formatted)
end

-- Print at the player's configured text speed (Trainer Tips path). The
-- cadence is injected into the controller at construction from the single
-- FieldPlayerData authority; the host never chooses one.
---@param message any
---@param bindings table|nil
---@param textArgs table|nil
function ScriptSignpostHost:printTyped(message, bindings, textArgs)
  local formatted = self._resolveMessage(message, bindings or {}, textArgs or {})
  self._controller:printTyped(formatted)
end

-- Stop a live typed printer, freezing the revealed text (directional
-- interruption and fault cleanup both call this).
function ScriptSignpostHost:stopPrint()
  self._controller:stopPrint()
end

-- The presentation snapshot, straight from the controller: plain data, no
-- LÖVE objects.
---@return FieldSignpostController.Status
function ScriptSignpostHost:status()
  return self._controller:status()
end

-- One fixed scheduler tick: the controller executes its current command and
-- advances its printer. The scheduler calls this from its engine-owned
-- advanceAsync callback once per tick.
function ScriptSignpostHost:advance()
  self._controller:updateFixed()
end

-- Fault/cancellation cleanup: stop any active printer, close the signpost
-- window, return the command to nop, and release modal ownership exactly
-- once (the controller's hide case also restores the default style).
-- Idempotent: a second close has no further effect.
function ScriptSignpostHost:close()
  local controller = self._controller
  controller:stopPrint()
  controller:setCommand("hide")
  controller:updateFixed()
end

return ScriptSignpostHost
