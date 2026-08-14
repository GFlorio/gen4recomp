-- FieldApplicationHost contract tests: the one application modal owner the
-- field session steps. The host owns the transition phase machine (closed/
-- opening_menu/menu/fading_out/application/fading_in/closing_menu plus the
-- terminal failed state), its own fixed-tick fade counter (fadeAlpha), the
-- Start Menu selection remembered across a child-application round trip,
-- the modal input lifetime (beginUi once at open, clearUi once on final
-- return or disposal), dispatch through the application registry, and
-- exactly-once disposal of the active controller on success, cancellation,
-- failure, reset, or runtime disposal. Fakes are the registry/input/
-- controller boundaries; the pointer mapping is exercised through the real
-- StartMenuLayout record.

local Assert = require("tests.support.Assert")
local ScreenTopology = require("libs.engine.src.ScreenTopology")
local FieldApplicationHost = require("libs.engine.src.FieldApplicationHost")

local T = {
  tests = {},
}

local function throws(fn)
  return Assert.throws(fn)
end

-- A minimal controller honoring the §17.1 contract; the test drives its
-- result through takeResult.
local function fakeController(overrides)
  local controller = {
    updateFixedCalls = 0,
    disposeCount = 0,
    cancelPointerCaptureCalls = 0,
    result = nil,
    receivedEvents = nil,
  }
  function controller:updateFixed(uiInput)
    self.updateFixedCalls = self.updateFixedCalls + 1
    self.receivedEvents = uiInput
  end
  function controller:status()
    return { open = true }
  end
  function controller:takeResult()
    local result = self.result
    self.result = nil
    return result
  end
  function controller:dispose()
    self.disposeCount = self.disposeCount + 1
  end
  function controller:cancelPointerCapture()
    self.cancelPointerCaptureCalls = self.cancelPointerCaptureCalls + 1
  end
  for key, value in pairs(overrides or {}) do
    controller[key] = value
  end
  return controller
end

local function fakeRegistry()
  local registry = {
    created = {},
    controllers = {},
  }
  -- Stored entries are either factories (functions, invoked with the
  -- dispatch arguments) or prebuilt controllers (returned as-is).
  function registry:create(id, ...)
    local stored = assert(self.controllers[id], "test registry has no controller for " .. id)
    self.created[#self.created + 1] = { id = id, args = { ... } }
    if type(stored) == "function" then
      return stored(...)
    end
    return stored
  end
  return registry
end

local function fakeInput()
  local input = {
    beginUiTicks = {},
    clearUiCalls = 0,
  }
  function input:beginUi(tick)
    self.beginUiTicks[#self.beginUiTicks + 1] = tick
  end
  function input:clearUi()
    self.clearUiCalls = self.clearUiCalls + 1
  end
  return input
end

-- The test fixture: a registry holding the menu composer (id start_menu) and
-- one destination, plus the input. Controllers are created lazily per id so
-- each construction is observable.
local function fixture()
  local registry = fakeRegistry()
  local input = fakeInput()
  local host = FieldApplicationHost.new({ registry = registry, input = input })
  return host, input, registry
end

local function openMenu(host, input, registry)
  registry.controllers.start_menu = fakeController()
  host:requestOpen(10)
  Assert.equal(input.beginUiTicks[1], 10)
  return registry.controllers.start_menu
end

function T.tests.construction_requires_the_registry_and_input()
  local registry = fakeRegistry()
  local input = fakeInput()
  throws(function()
    local partial = { input = input } ---@type any
    FieldApplicationHost.new(partial)
  end)
  throws(function()
    local partial = { registry = registry } ---@type any
    FieldApplicationHost.new(partial)
  end)
  throws(function()
    local partial = {} ---@type any
    FieldApplicationHost.new(partial)
  end)
end

function T.tests.starts_closed_with_no_fade_and_no_menu()
  local host, _, _ = fixture()
  local status = host:status()
  Assert.equal(status.phase, "closed")
  Assert.equal(status.fadeAlpha, 0)
  Assert.isNil(status.applicationId)
  Assert.isNil(status.menu)
  Assert.equal(host:isActive(), false)
end

function T.tests.open_constructs_the_menu_through_the_registry_and_begins_ui_once()
  local host, input, registry = fixture()
  local controller = openMenu(host, input, registry)
  Assert.equal(host:status().phase, "opening_menu")
  Assert.equal(host:status().menu.open, true)
  Assert.equal(host:isActive(), true)
  Assert.equal(#registry.created, 1)
  Assert.equal(registry.created[1].id, "start_menu")
  Assert.deepEqual(registry.created[1].args, { nil })
  Assert.equal(controller.disposeCount, 0)
end

function T.tests.opening_menu_arms_the_menu_phase_on_the_following_tick()
  local host, input, registry = fixture()
  openMenu(host, input, registry)
  local controller = registry.controllers.start_menu
  host:updateFixed(11, { { type = "confirm" } })
  Assert.equal(host:status().phase, "menu")
  host:updateFixed(12, { { type = "navigate", direction = "down" } })
  Assert.equal(host:status().phase, "menu")
  Assert.equal(controller.updateFixedCalls, 1)
  Assert.equal(controller.receivedEvents[1].type, "navigate")
end

function T.tests.launch_freeze_menu_input_then_fades_out_and_dispatches_the_destination()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  host:updateFixed(12, { { type = "confirm" } })
  Assert.equal(host:status().phase, "fading_out")
  Assert.equal(host:status().fadeAlpha, 0)
  Assert.equal(host:status().applicationId, "trainer_card")
  -- The menu controller is not disposed until the fade hides the world, and
  -- it is not stepped during the fade (input is frozen).
  Assert.equal(menu.disposeCount, 0)
  Assert.equal(menu.updateFixedCalls, 1)
  local fadeTicks = FieldApplicationHost.FADE_TICKS
  for tick = 1, fadeTicks - 1 do
    host:updateFixed(12 + tick, { { type = "cancel" } })
    Assert.equal(host:status().phase, "fading_out")
    Assert.equal(host:status().fadeAlpha, tick / fadeTicks)
  end
  host:updateFixed(12 + fadeTicks, { { type = "cancel" } })
  Assert.equal(host:status().phase, "application")
  Assert.equal(host:status().fadeAlpha, 1)
  Assert.equal(menu.disposeCount, 1, "the menu controller is disposed exactly once at the fade-out end")
  Assert.equal(#registry.created, 2)
  Assert.equal(registry.created[2].id, "trainer_card")
  -- The destination receives its first step in its construction tick with
  -- no events: menu input was frozen for the whole fade, so presses from the
  -- fade period must never reach the destination.
  Assert.equal(destination.updateFixedCalls, 1)
  Assert.equal(#destination.receivedEvents, 0, "the fade-period input never reaches the destination")
end

function T.tests.application_steps_the_destination_once_per_tick_until_close()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed(tick, {})
  end
  Assert.equal(host:status().phase, "application")
  host:updateFixed(30, { { type = "cancel" } })
  Assert.equal(destination.receivedEvents[1].type, "cancel", "the destination receives the tick events")
  host:updateFixed(31, {})
  Assert.equal(destination.updateFixedCalls, 3)
end

function T.tests.destination_close_disposes_exactly_once_and_fades_back_in()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed(tick, {})
  end
  destination.result = { kind = "close" }
  host:updateFixed(30, { { type = "cancel" } })
  Assert.equal(destination.disposeCount, 1, "the returned destination is disposed exactly once")
  Assert.equal(host:status().phase, "fading_in")
  Assert.equal(host:status().fadeAlpha, 1)
  local fadeTicks = FieldApplicationHost.FADE_TICKS
  for tick = 1, fadeTicks - 1 do
    host:updateFixed(30 + tick, {})
    Assert.equal(host:status().fadeAlpha, 1 - tick / fadeTicks)
  end
  host:updateFixed(30 + fadeTicks, {})
  Assert.equal(host:status().fadeAlpha, 0)
  Assert.equal(host:status().phase, "menu")
  Assert.equal(destination.disposeCount, 1, "the destination is never disposed twice")
end

function T.tests.menu_rebuild_restores_the_remembered_selection_by_action_id()
  local host, input, registry = fixture()
  local menu = openMenu(host, input, registry)
  host:updateFixed(11, {})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed(tick, {})
  end
  destination.result = { kind = "close" }
  host:updateFixed(30, { { type = "cancel" } })
  local rebuilt = fakeController()
  registry.controllers.start_menu = rebuilt
  for tick = 31, 30 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed(tick, {})
  end
  Assert.equal(host:status().phase, "menu")
  Assert.equal(#registry.created, 3)
  Assert.equal(registry.created[3].id, "start_menu")
  Assert.equal(registry.created[3].args[1], "vanilla.trainer_card", "the rebuild passes the remembered action id")
  Assert.equal(input.beginUiTicks[1], 10, "the input lifetime is begun exactly once")
  Assert.equal(input.beginUiTicks[2], nil, "the child round trip never nests beginUi")
  Assert.equal(input.clearUiCalls, 0, "ownership is retained across the child round trip")
end

function T.tests.menu_close_disposes_controller_and_releases_ownership_once()
  local host, input, registry = fixture()
  local menu = openMenu(host, input, registry)
  host:updateFixed(11, {})
  menu.result = { kind = "close" }
  host:updateFixed(12, { { type = "menu" } })
  Assert.equal(menu.disposeCount, 1, "the closing menu controller is disposed exactly once")
  Assert.equal(input.clearUiCalls, 1, "the final field return releases the modal input lifetime once")
  Assert.equal(host:status().phase, "closing_menu")
  host:updateFixed(13, {})
  Assert.equal(host:status().phase, "closed")
  Assert.equal(host:isActive(), false)
  Assert.equal(host:status().fadeAlpha, 0)
end

function T.tests.update_fixed_requires_an_active_host()
  local host, _, _ = fixture()
  throws(function()
    host:updateFixed(1, {})
  end)
end

function T.tests.open_while_active_is_a_programming_invariant()
  local host, _, registry = fixture()
  registry.controllers.start_menu = fakeController()
  host:requestOpen(10)
  throws(function()
    host:requestOpen(11)
  end)
end

function T.tests.destination_factory_failure_after_fade_out_retains_the_error_and_never_reports_a_menu_return()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  registry.controllers.trainer_card = function()
    error("injected destination factory failure")
  end
  for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed(tick, {})
  end
  Assert.equal(host:status().phase, "failed")
  Assert.isTrue(tostring(host:error()):find("injected destination factory failure", 1, true) ~= nil)
  Assert.equal(menu.disposeCount, 1, "the failed dispatch still disposes the menu controller exactly once")
  local phase = host:status().phase
  Assert.isTrue(phase ~= "menu" and phase ~= "closed", "a failed destination must not report a successful return")
  Assert.equal(host:isActive(), true, "the failed host stays active so the world never resumes")
  host:updateFixed(99, {})
  Assert.equal(host:status().phase, "failed", "the failed phase is terminal")
end

function T.tests.menu_composition_failure_at_open_acquires_nothing()
  local host, input, registry = fixture()
  registry.controllers.start_menu = function()
    error("injected menu composition failure")
  end
  host:requestOpen(10)
  Assert.equal(host:status().phase, "failed")
  Assert.equal(input.beginUiTicks[1], nil, "a failed composition never begins the modal input lifetime")
  Assert.equal(input.clearUiCalls, 0)
  Assert.isTrue(tostring(host:error()):find("injected menu composition failure", 1, true) ~= nil)
end

function T.tests.menu_rebuild_failure_after_return_is_retained_after_the_destination_disposal()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed(tick, {})
  end
  destination.result = { kind = "close" }
  host:updateFixed(30, { { type = "cancel" } })
  Assert.equal(destination.disposeCount, 1)
  registry.controllers.start_menu = function()
    error("injected rebuild failure")
  end
  for tick = 31, 30 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed(tick, {})
  end
  Assert.equal(host:status().phase, "failed")
  Assert.equal(destination.disposeCount, 1, "the returned destination is never disposed twice")
  Assert.isTrue(tostring(host:error()):find("injected rebuild failure", 1, true) ~= nil)
end

function T.tests.reopen_request_is_consumed_by_take_reopen_once()
  local host, input, registry = fixture()
  registry.controllers.start_menu = fakeController()
  host:requestReopen()
  Assert.equal(host:takeReopen(20), true)
  Assert.equal(input.beginUiTicks[1], 20)
  Assert.equal(host:takeReopen(21), false, "a consumed reopen request never opens twice")
  local second, secondInput, secondRegistry = fixture()
  secondRegistry.controllers.start_menu = fakeController()
  second:requestReopen()
  second:requestReopen()
  Assert.equal(second:takeReopen(22), true, "a repeated request is a single pending open")
  Assert.equal(secondInput.beginUiTicks[1], 22)
end

function T.tests.reopen_while_active_is_a_programming_invariant()
  local host, _, registry = fixture()
  registry.controllers.start_menu = fakeController()
  host:requestOpen(10)
  throws(function()
    host:requestReopen()
  end)
end

-- The per-phase disposal matrix: runtime disposal in every phase releases
-- the active controller exactly once and the modal input lifetime once.
function T.tests.dispose_in_every_phase_releases_exactly_once()
  local cases = {
    { phase = "closed", controllers = 0, clears = 0 },
    { phase = "opening_menu", controllers = 1, clears = 1 },
    { phase = "menu", controllers = 1, clears = 1 },
    { phase = "fading_out", controllers = 1, clears = 1 },
    { phase = "application", controllers = 1, clears = 1 },
    { phase = "fading_in", controllers = 0, clears = 1 },
    { phase = "closing_menu", controllers = 0, clears = 1 },
    { phase = "failed", controllers = 0, clears = 1 },
  }
  for _, case in ipairs(cases) do
    local host, input, registry = fixture()
    local menu = fakeController()
    local destination = fakeController()
    registry.controllers.start_menu = menu
    registry.controllers.trainer_card = destination
    if case.phase == "opening_menu" then
      host:requestOpen(10)
    elseif case.phase == "menu" then
      host:requestOpen(10)
      host:updateFixed(11, {})
    elseif case.phase == "fading_out" then
      host:requestOpen(10)
      host:updateFixed(11, {})
      menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
      host:updateFixed(12, {})
    elseif case.phase == "application" then
      host:requestOpen(10)
      host:updateFixed(11, {})
      menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
      for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
        host:updateFixed(tick, {})
      end
    elseif case.phase == "fading_in" then
      host:requestOpen(10)
      host:updateFixed(11, {})
      menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
      for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
        host:updateFixed(tick, {})
      end
      destination.result = { kind = "close" }
      host:updateFixed(30, { { type = "cancel" } })
    elseif case.phase == "closing_menu" then
      host:requestOpen(10)
      host:updateFixed(11, {})
      menu.result = { kind = "close" }
      host:updateFixed(12, { { type = "menu" } })
    elseif case.phase == "failed" then
      host:requestOpen(10)
      host:updateFixed(11, {})
      menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
      registry.controllers.trainer_card = function()
        error("injected failure")
      end
      for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
        host:updateFixed(tick, {})
      end
    end
    host:dispose()
    local menuDisposed = case.phase ~= "closed"
    local destinationDisposed = case.phase == "application" or case.phase == "fading_in"
    Assert.equal(menu.disposeCount, menuDisposed and 1 or 0, case.phase .. " must dispose the menu exactly once")
    Assert.equal(
      destination.disposeCount,
      destinationDisposed and 1 or 0,
      case.phase .. " must dispose the destination exactly once"
    )
    Assert.equal(input.clearUiCalls, case.clears, case.phase .. " must release the input lifetime once")
    Assert.equal(host:status().phase, "closed")
    Assert.equal(host:isActive(), false)
    host:dispose()
    Assert.equal(menu.disposeCount <= 1, true, case.phase .. " dispose must be idempotent")
    Assert.equal(destination.disposeCount <= 1, true, case.phase .. " dispose must be idempotent")
    Assert.equal(input.clearUiCalls, case.clears, case.phase .. " clearUi must stay exactly once")
  end
end

function T.tests.resize_recomputes_placement_and_cancels_the_menu_pointer_capture()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  host:setScreenTopology(ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    role = "world",
    touch = false,
  }))
  Assert.equal(menu.cancelPointerCaptureCalls, 1, "a resize cancels an active menu pointer capture")
end

function T.tests.pointer_events_are_mapped_through_the_layout_for_the_menu_controller()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  host:setScreenTopology(ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    role = "world",
    touch = false,
  }))
  host:updateFixed(12, {
    { type = "pointer_down", pointerId = "p1", x = 64, y = 48 },
    { type = "pointer_move", x = 400, y = 100 },
    { type = "pointer_up", pointerId = "p1", x = 64, y = 48 },
    { type = "pointer_scroll", pointerId = "p1", dx = 0, dy = -1 },
  })
  local events = menu.receivedEvents
  Assert.equal(events[1].type, "pointer_down")
  Assert.equal(events[1].x, 64, "host coordinates map to canonical logical coordinates")
  Assert.equal(events[1].y, 48)
  Assert.equal(events[2].type, "pointer_up", "an event outside the menu frame is dropped")
  Assert.equal(events[2].x, 64)
  Assert.equal(events[3].type, "pointer_scroll", "scroll events pass through unchanged")
  Assert.equal(events[3].dx, 0)
  Assert.equal(events[4], nil)
end

function T.tests.pointer_events_are_dropped_without_a_screen_topology()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  host:updateFixed(12, { { type = "pointer_down", pointerId = "p1", x = 64, y = 48 } })
  Assert.equal(menu.receivedEvents[1], nil, "no topology means no pointer support in the non-rendering composition")
end

function T.tests.destination_controllers_receive_events_passthrough()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  host:setScreenTopology(ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    role = "world",
    touch = false,
  }))
  for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed(tick, {})
  end
  host:updateFixed(30, { { type = "cancel" }, { type = "pointer_down", pointerId = "p1", x = 0, y = 0 } })
  Assert.equal(destination.receivedEvents[1].type, "cancel")
  Assert.equal(destination.receivedEvents[2].type, "pointer_down", "destinations own their input policy")
end

function T.tests.a_destination_launch_result_is_a_programming_invariant()
  local host, _, registry = fixture()
  local menu = openMenu(host, _, registry)
  host:updateFixed(11, {})
  menu.result = { kind = "launch", applicationId = "trainer_card", actionId = "vanilla.trainer_card" }
  local destination = fakeController()
  registry.controllers.trainer_card = destination
  for tick = 12, 12 + FieldApplicationHost.FADE_TICKS do
    host:updateFixed(tick, {})
  end
  destination.result = { kind = "launch", applicationId = "pokedex" }
  throws(function()
    host:updateFixed(30, {})
  end)
end

return T
