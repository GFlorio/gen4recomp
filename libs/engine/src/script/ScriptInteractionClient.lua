-- Script interaction client : the construction
-- point that replaced the pre-script interaction adapter. It resolves an
-- immutable InteractionIntent through the bindings manifest into a trigger
-- descriptor, composes the bound script, and starts it as the foreground
-- root through the scheduler so a newly resolved interaction may execute
-- during its trigger tick. The binding audit at load time guarantees every
-- interactable event is bound, so an unmapped intent reaching this client is
-- a composition fault (the session asserts on it) — there is no fallback.
-- Pure domain module: no love dependency.

---@class ScriptInteractionClient
---@field private _bindings table
---@field private _compose fun(scriptId: string): table|nil
---@field private _scheduler Scheduler
local ScriptInteractionClient = {}
ScriptInteractionClient.__index = ScriptInteractionClient

-- The consume() outcome protocol shared with FieldSession: a consumed intent
-- either started a foreground script, found the field already owned, or was
-- unmapped (a composition fault the session asserts on). The session and
-- every consumer read these constants, never the literal strings.
ScriptInteractionClient.RESULTS = {
  started = "started",
  blocked = "blocked",
  unmapped = "unmapped",
}

---@param opts table
---@return ScriptInteractionClient
function ScriptInteractionClient.new(opts)
  assert(
    opts and opts.bindings and opts.compose and opts.scheduler,
    "interaction client requires bindings, compose, and scheduler"
  )
  return setmetatable({
    _bindings = opts.bindings,
    _compose = opts.compose,
    _scheduler = opts.scheduler,
  }, ScriptInteractionClient)
end

-- Resolve one intent into a trigger + composed descriptor, or nil when the
-- map event is not bound.
---@param intent table InteractionIntent
---@return table|nil { trigger, composed }
function ScriptInteractionClient:resolve(intent)
  local hit = self._bindings:resolveIntent(intent, intent.playerFacing)
  if hit == nil then
    return nil
  end
  local composed = self._compose(hit.scriptId)
  if composed == nil then
    return nil
  end
  return { trigger = hit.trigger, composed = composed }
end

-- Consume one interaction intent. Returns the RESULTS.started outcome when a
-- script now owns the field, RESULTS.blocked when a foreground script already
-- owns it, or RESULTS.unmapped when nothing is bound (the session treats that
-- as a composition fault: the binding audit guarantees every interactable
-- event is bound). A started script may execute during this tick.
---@param intent table InteractionIntent
---@param tick integer
---@return string started|blocked|unmapped
function ScriptInteractionClient:consume(intent, tick)
  if self._scheduler:foregroundEnvironmentId() ~= nil then
    return ScriptInteractionClient.RESULTS.blocked
  end
  local hit = self:resolve(intent)
  if hit == nil then
    return ScriptInteractionClient.RESULTS.unmapped
  end
  self._scheduler:startInteraction(hit.trigger, hit.composed, tick)
  return ScriptInteractionClient.RESULTS.started
end

return ScriptInteractionClient
