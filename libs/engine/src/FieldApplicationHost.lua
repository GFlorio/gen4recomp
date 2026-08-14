-- The one application modal owner the field session steps: it owns the
-- active application ID and controller, the transition phase machine
-- (closed/opening_menu/menu/fading_out/application/fading_in/closing_menu,
-- plus the terminal failed state for §27.1 factory/composition failures),
-- the Start Menu selection remembered across a child-application round
-- trip, the modal input lifetime (beginUi once at open, clearUi once on
-- final field return or disposal), dispatch through the sealed
-- FieldApplicationRegistry, and exactly-once disposal of the active
-- controller on success, cancellation, failure, reset, or runtime disposal.
-- Its own fixed-tick fade counter exposes fadeAlpha; FieldTransition is not
-- reused (it owns warp preparation, map protection, and map swaps). The
-- host never launches a child by itself: the menu controller records
-- { kind = "launch", applicationId } results and the host dispatches them
-- through the registry only after the fade-out hides the world. Pure
-- module: no love, no I/O; pointer events are mapped through
-- StartMenuLayout's record when a screen topology is set.

local StartMenuLayout = require("libs.engine.src.StartMenuLayout")

---@class FieldApplicationHostOptions
---@field registry FieldApplicationRegistry the sealed per-runtime application catalogue
---@field input FieldInput the field input whose modal lifetime the host acquires/releases

---@class FieldApplicationHost
---@field _registry FieldApplicationRegistry
---@field _input FieldInput
---@field _phase string
---@field _fadeTicks integer
---@field _fadeAlpha number
---@field _controller table? the active controller (menu or destination)
---@field _rememberedActionId string?
---@field _applicationId string?
---@field _failure any? retained factory/composition failure
---@field _uiHeld boolean the modal input lifetime is held (beginUi done, clearUi pending)
---@field _reopenPending boolean a script reopen request awaits the session
---@field _layout table? the StartMenuLayout placement record (setScreenTopology)
local FieldApplicationHost = {}
FieldApplicationHost.__index = FieldApplicationHost

-- The host's own fixed-tick fade counter: the same 12-tick cadence as the
-- field transition's warp fades. The spec pins the phase sequence, not the
-- fade length; the counter is the single fadeAlpha authority.
FieldApplicationHost.FADE_TICKS = 12

-- The normal lifecycle phases (§17.1) plus the terminal failure state
-- (§27.1: "leave the runtime in one terminally consistent state").
FieldApplicationHost.PHASES = {
  closed = "closed",
  opening_menu = "opening_menu",
  menu = "menu",
  fading_out = "fading_out",
  application = "application",
  fading_in = "fading_in",
  closing_menu = "closing_menu",
  failed = "failed",
}

local PHASE_NAMES = {}
for name in pairs(FieldApplicationHost.PHASES) do
  PHASE_NAMES[name] = true
end

---@param options FieldApplicationHostOptions
---@return FieldApplicationHost
function FieldApplicationHost.new(options)
  assert(options and options.registry and options.registry.create, "the application host requires the registry")
  assert(
    options and options.input and options.input.beginUi and options.input.clearUi,
    "the application host requires the input"
  )
  return setmetatable({
    _registry = options.registry,
    _input = options.input,
    _phase = FieldApplicationHost.PHASES.closed,
    _fadeTicks = 0,
    _fadeAlpha = 0,
    _controller = nil,
    _rememberedActionId = nil,
    _applicationId = nil,
    _failure = nil,
    _uiHeld = false,
    _reopenPending = false,
    _layout = nil,
  }, FieldApplicationHost)
end

-- The §17.1/§41 presentation snapshot: the phase, the host-owned fade
-- alpha, the active application id (while a destination owns the tick or is
-- being entered/left), the Start Menu presentation status while the menu
-- phases run, and the active destination's own presentation status while
-- the application phase runs (the §17.1 renderer channel: FieldState
-- chooses the destination renderer from this snapshot; only the one active
-- modal surface is presented).
---@return { phase: string, fadeAlpha: number, applicationId?: string, menu?: table, application?: table }
function FieldApplicationHost:status()
  local phase = self._phase
  local status = {
    phase = phase,
    fadeAlpha = self._fadeAlpha,
  }
  if self._applicationId ~= nil then
    status.applicationId = self._applicationId
  end
  local controller = self._controller
  if
    controller ~= nil
    and (phase == FieldApplicationHost.PHASES.opening_menu or phase == FieldApplicationHost.PHASES.menu)
  then
    status.menu = controller:status()
  end
  if controller ~= nil and phase == FieldApplicationHost.PHASES.application then
    status.application = controller:status()
  end
  return status
end

-- Whether the host owns the tick: while active, the field session steps no
-- world simulation and the save gate stays closed.
---@return boolean
function FieldApplicationHost:isActive()
  return self._phase ~= FieldApplicationHost.PHASES.closed
end

-- The retained factory/composition failure, or nil. The runtime surfaces it
-- as its fatal error text and freezes.
---@return any?
function FieldApplicationHost:error()
  return self._failure
end

-- The single acquisition point: constructs the Start Menu through the
-- registry (the menu application's factory is the runtime's composition
-- step), begins the modal input lifetime, and enters the opening phase. A
-- failed composition acquires nothing and leaves the host terminally
-- failed with the original error retained.
---@param tick integer
function FieldApplicationHost:requestOpen(tick)
  assert(self._phase == FieldApplicationHost.PHASES.closed, "the application host must be closed to open the menu")
  assert(tick == math.floor(tick) and tick >= 0, "the menu open requires a non-negative tick")
  self:_openMenu(tick, nil)
end

-- Script-side reopen request (the opcode-61 startMenuReopen service): the
-- request is queued and the session consumes it through takeReopen at its
-- post-scheduler arbitration point, so the open consumes a tick of its own.
function FieldApplicationHost:requestReopen()
  assert(self._phase == FieldApplicationHost.PHASES.closed, "a reopen must not target an active application")
  self._reopenPending = true
end

-- Consumes a pending script reopen request by opening the menu; returns
-- whether an open happened.
---@param tick integer
---@return boolean
function FieldApplicationHost:takeReopen(tick)
  if not self._reopenPending then
    return false
  end
  self._reopenPending = false
  self:_openMenu(tick, nil)
  return true
end

-- The menu construction shared by open and reopen. The controller is built
-- through the registry factory before beginUi so a failed composition never
-- begins the input lifetime; beginUi flushes stale UI edges at modal
-- ownership begin so the opening edge cannot immediately close the menu it
-- opened.
---@param tick integer
---@param rememberedActionId string?
function FieldApplicationHost:_openMenu(tick, rememberedActionId)
  local ok, controller = pcall(self._registry.create, self._registry, "start_menu", rememberedActionId)
  if not ok then
    self:_fail(controller)
    return
  end
  self._controller = controller
  self._rememberedActionId = rememberedActionId
  self._input:beginUi(tick)
  self._uiHeld = true
  self._fadeTicks = 0
  self._fadeAlpha = 0
  self._phase = FieldApplicationHost.PHASES.opening_menu
end

-- Terminal failure ownership: retain the original error, release anything
-- acquired, and freeze the host. No successful return to the menu is ever
-- reported; the runtime surfaces the error and stops stepping.
---@param failure any
function FieldApplicationHost:_fail(failure)
  self._failure = failure
  self._phase = FieldApplicationHost.PHASES.failed
end

-- Disposes the active controller exactly once (idempotent).
function FieldApplicationHost:_disposeController()
  local controller = self._controller
  self._controller = nil
  if controller ~= nil then
    controller:dispose()
  end
end

-- Releases the modal input lifetime exactly once (the final field return or
-- host disposal).
function FieldApplicationHost:_releaseUi()
  if self._uiHeld then
    self._input:clearUi()
    self._uiHeld = false
  end
end

-- Rebuilds the Start Menu after a child-application return with the
-- remembered selection by action id. A failed rebuild is retained after the
-- destination's own disposal; nothing re-enters the menu.
function FieldApplicationHost:_rebuildMenu()
  local remembered = self._rememberedActionId
  local ok, controller = pcall(self._registry.create, self._registry, "start_menu", remembered)
  if not ok then
    self:_fail(controller)
    return
  end
  self._controller = controller
  self._applicationId = nil
  self._phase = FieldApplicationHost.PHASES.menu
end

-- One fixed tick of the phase machine. The session steps the host exactly
-- once per tick while it is active and feeds it the single UI event list of
-- the tick; no other modal controller receives the same events.
---@param tick integer
---@param uiInput table[]
function FieldApplicationHost:updateFixed(tick, uiInput)
  assert(self._phase ~= FieldApplicationHost.PHASES.closed, "a closed host is not stepped")
  local phase = self._phase
  if phase == FieldApplicationHost.PHASES.failed then
    return
  end
  if phase == FieldApplicationHost.PHASES.opening_menu then
    -- The opening tick arms nothing: input becomes live with the menu phase.
    self._phase = FieldApplicationHost.PHASES.menu
    return
  end
  if phase == FieldApplicationHost.PHASES.menu then
    self:_stepMenu(tick, uiInput)
    return
  end
  if phase == FieldApplicationHost.PHASES.fading_out then
    self:_stepFadeOut(tick, uiInput)
    return
  end
  if phase == FieldApplicationHost.PHASES.application then
    self:_stepApplication(tick, uiInput)
    return
  end
  if phase == FieldApplicationHost.PHASES.fading_in then
    self:_stepFadeIn(tick)
    return
  end
  if phase == FieldApplicationHost.PHASES.closing_menu then
    self._phase = FieldApplicationHost.PHASES.closed
    self._fadeAlpha = 0
    return
  end
  error("unknown application host phase " .. tostring(phase), 2)
end

-- Maps one UI event list for the menu controller: pointer events travel
-- through the StartMenuLayout record (host coordinates -> canonical logical
-- 0..255 x 0..191); events outside the menu frame are dropped. Without a
-- screen topology there is no pointer support at all. Non-pointer events and
-- the destination controller's events pass through unchanged (destinations
-- own their input policy).
---@param uiInput table[]
---@param mapPointers boolean
---@return table[]
function FieldApplicationHost:_mapEvents(uiInput, mapPointers)
  if not mapPointers then
    return uiInput
  end
  if self._layout == nil then
    local withoutPointers = {}
    for _, event in ipairs(uiInput) do
      if not (type(event) == "table" and type(event.x) == "number" and type(event.y) == "number") then
        withoutPointers[#withoutPointers + 1] = event
      end
    end
    return withoutPointers
  end
  local mapped = {}
  for _, event in ipairs(uiInput) do
    if type(event) == "table" and type(event.x) == "number" and type(event.y) == "number" then
      local x, y = StartMenuLayout.hostToLogical(self._layout, event.x, event.y)
      if x ~= nil then
        mapped[#mapped + 1] = {
          type = event.type,
          pointerId = event.pointerId,
          x = x,
          y = y,
          dragged = event.dragged,
        }
      end
    else
      mapped[#mapped + 1] = event
    end
  end
  return mapped
end

-- The menu phase: one controller step with the tick's (mapped) events, then
-- the recorded result is dispatched. A launch freezes further menu input
-- and starts the fade-out; a close disposes the menu exactly once and
-- releases the input lifetime on the final field return.
---@param tick integer
---@param uiInput table[]
function FieldApplicationHost:_stepMenu(tick, uiInput)
  local controller = assert(self._controller, "the menu phase requires the menu controller")
  controller:updateFixed(self:_mapEvents(uiInput, true))
  local result = controller:takeResult()
  if result == nil then
    return
  end
  assert(result.kind == "launch" or result.kind == "close", "unknown menu result kind")
  if result.kind == "launch" then
    assert(type(result.applicationId) == "string", "a menu launch needs a destination id")
    -- The remembered selection rides the launch result: the host restores
    -- the rebuilt menu's selection by this action id after the round trip.
    self._rememberedActionId = result.actionId
    self._applicationId = result.applicationId
    self._fadeTicks = 0
    self._fadeAlpha = 0
    self._phase = FieldApplicationHost.PHASES.fading_out
  else
    self:_disposeController()
    self:_releaseUi()
    self._phase = FieldApplicationHost.PHASES.closing_menu
  end
end

-- The fade-out: the host's own fixed-tick counter moves fadeAlpha 0 -> 1.
-- When the world is hidden the Start Menu presentation is disposed exactly
-- once and the destination is constructed through the registry; the
-- destination receives its first step in its construction tick with no
-- events -- menu input was frozen for the whole fade (§27.1), so presses
-- from the fade period must never reach the destination.
---@param tick integer
---@param uiInput table[]
function FieldApplicationHost:_stepFadeOut(tick, uiInput)
  self._fadeTicks = self._fadeTicks + 1
  self._fadeAlpha = math.min(1, self._fadeTicks / FieldApplicationHost.FADE_TICKS)
  if self._fadeTicks < FieldApplicationHost.FADE_TICKS then
    return
  end
  self:_disposeController()
  local applicationId = assert(self._applicationId, "the fade-out requires the destination id")
  local ok, controller = pcall(self._registry.create, self._registry, applicationId)
  if not ok then
    -- §27.1: retain the original error, release anything the failed
    -- factory/host acquired, and leave the runtime terminally consistent.
    self:_fail(controller)
    return
  end
  self._controller = controller
  self._phase = FieldApplicationHost.PHASES.application
  controller:updateFixed({})
end

-- The application phase: the destination is stepped once per fixed tick
-- with the tick's events; its close result disposes it exactly once and
-- starts the fade-in back to the rebuilt menu.
---@param tick integer
---@param uiInput table[]
function FieldApplicationHost:_stepApplication(tick, uiInput)
  local controller = assert(self._controller, "the application phase requires the destination controller")
  controller:updateFixed(self:_mapEvents(uiInput, false))
  local result = controller:takeResult()
  if result == nil then
    return
  end
  assert(result.kind == "close", "a destination controller only returns close")
  self:_disposeController()
  self._fadeTicks = 0
  self._fadeAlpha = 1
  self._phase = FieldApplicationHost.PHASES.fading_in
end

-- The fade-in: the counter moves fadeAlpha 1 -> 0; at the fully restored
-- boundary the menu is rebuilt from current policy/capabilities with the
-- remembered selection and input arms again.
---@param tick integer
function FieldApplicationHost:_stepFadeIn(tick)
  self._fadeTicks = self._fadeTicks + 1
  self._fadeAlpha = math.max(0, 1 - self._fadeTicks / FieldApplicationHost.FADE_TICKS)
  if self._fadeTicks < FieldApplicationHost.FADE_TICKS then
    return
  end
  self:_rebuildMenu()
end

-- Recomputes the StartMenuLayout placement record for a new screen
-- topology. A press held across a resize must not activate a different
-- post-resize slot, so an active menu pointer capture is cancelled.
---@param topology table?
function FieldApplicationHost:setScreenTopology(topology)
  self._layout = topology ~= nil and StartMenuLayout.resolve(topology) or nil
  local controller = self._controller
  if controller ~= nil and type(controller.cancelPointerCapture) == "function" then
    controller:cancelPointerCapture()
  end
end

-- The one teardown path for reset and runtime disposal: dispose the active
-- controller exactly once, release the modal input lifetime once, and
-- return to closed. Idempotent.
function FieldApplicationHost:dispose()
  if self._phase == FieldApplicationHost.PHASES.closed and self._controller == nil then
    return
  end
  self:_disposeController()
  self:_releaseUi()
  self._reopenPending = false
  self._applicationId = nil
  self._failure = nil
  self._fadeTicks = 0
  self._fadeAlpha = 0
  self._phase = FieldApplicationHost.PHASES.closed
end

return FieldApplicationHost
