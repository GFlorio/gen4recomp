-- trainer_tips_print task implementation : the native
-- waiter for opcode 59 (TrainerTips). Creation starts the typed print at the
-- player's configured text speed through the injected signpost host (the
-- cadence is the controller's injected FieldPlayerData authority; the task
-- never chooses one). The poll reads only the fixed-tick input edges: a
-- directional edge before the print completes is the source interruption
-- (ScrCmd_TrainerTips / NativeScript_WaitTrainerTips, src/scrcmd_c.c at the
-- pinned decomp commit) — the explicit cleanup cuts the print off and
-- closes the window, the player turns to that direction, and the task
-- completes 0; A/B during the
-- print is the instant-fill operation (the whole message reveals through
-- host:finishPrint, the window stays open, and the task completes 2, the
-- same result as normal completion); on a live-print tick the direction wins
-- over A/B. A completed print completes 2 before any edge is considered,
-- and the print path reads no pointer edge (the script input snapshot has
-- none), so touch can never fill the print. The completion value flows
-- through the scheduler result reference (node.result), never a direct world
-- write. Pure domain module: no love dependency.

local Errors = require("libs.errors.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")

local TrainerTipsTask = {}

TrainerTipsTask.type = "trainer_tips_print"
TrainerTipsTask.version = 1

---@param spec table
---@param ctx table
---@return table state
function TrainerTipsTask.create(spec, ctx)
  local node = assert(spec.node, "trainer tips requires its graph node")
  local host = ctx.services.signpost
  if host == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "signpost service is unavailable",
      { scriptId = ctx.instance.scriptId }
    )
  end
  -- LuaLS cannot see through Errors.raise; the raise never returns nil.
  ---@cast host ScriptSignpostHost
  host:printTyped(node.message, nil, ctx.instance.textArgs or {})
  return { waiting = true }
end

---@param state table
---@param ctx table
---@return table
function TrainerTipsTask.poll(state, ctx)
  local host = ctx.services.signpost
  if host == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_SERVICE_MISSING,
      "signpost service is unavailable",
      { scriptId = ctx.instance.scriptId }
    )
  end
  -- LuaLS cannot see through Errors.raise; the raise never returns nil.
  ---@cast host ScriptSignpostHost
  -- Completion wins: an edge in the tick the print finished is after the
  -- fact, exactly like the source printer's "before printing completes".
  if host:status().printDone then
    return { complete = true, state = state, result = 2 }
  end
  local input = ctx.input or {}
  if input.pressedDirection then
    -- The directional interruption: the host cleanup clears the printer and
    -- closes the window, returning the command to idle; the player turns to
    -- the pressed direction and the task completes 0. Direction wins over
    -- A/B on the same live-print tick.
    ctx.services.player:turn(input.pressedDirection)
    host:close()
    return { complete = true, state = state, result = 0 }
  end
  if input.pressedAction or input.pressedCancel then
    -- The instant-fill operation: the whole message reveals immediately, the
    -- window stays presented, and the task completes with the normal
    -- print-complete result 2.
    host:finishPrint()
    return { complete = true, state = state, result = 2 }
  end
  return { complete = false, state = state }
end

-- Fault/cancellation cleanup: the task owns the live print it started, so
-- closing the signpost clears the printer and window, returns the command
-- to idle, and releases modal ownership exactly once. A task that
-- already completed owns nothing.
---@param state table
---@param reason string
---@param ctx table|nil
function TrainerTipsTask.cancel(state, reason, ctx)
  state.cancelled = reason
  if ctx ~= nil and ctx.services ~= nil and ctx.services.signpost ~= nil then
    ctx.services.signpost:close()
  end
end

---@param state table
---@return Errors.Error|nil
function TrainerTipsTask.validate(state)
  if type(state) ~= "table" or state.waiting ~= true then
    return Errors.new(
      ScriptErrors.SCRIPT_TASK_UNSERIALIZABLE,
      "trainer_tips_print state must hold the waiting marker",
      { state = state }
    )
  end
  return nil
end

return TrainerTipsTask
