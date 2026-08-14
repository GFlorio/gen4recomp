-- Production-composed application registry and Start Menu transition contract:
-- the runtime must expose a sealed per-runtime application registry populated
-- before seal (the start_menu and trainer_card factories are
-- production-registered; a boot-config descriptor supplies the mod fake
-- destination this journey launches), and an application host owning the
-- transition phase machine (closed/opening_menu/menu/fading_out/application/
-- fading_in/closing_menu), the fixed-tick fade counter, and exactly-once
-- controller disposal. One boot walks the full lifecycle with a registered
-- mod destination: ineligible open edges acquire nothing, the menu opens at
-- an idle boundary, world simulation stays paused across the child
-- application, the destination is constructed through the registry factory
-- and disposed exactly once on return, the menu rebuilds with the remembered
-- selection, the closing edges leak nothing into the field, and runtime
-- disposal mid-menu defers the save and releases cleanly. The second boot
-- pins the capability gate in developer mode (capability-missing canonical
-- entries rendered disabled) and the destination-factory failure after
-- fade-out: the original error is retained, no successful return to the menu
-- is reported, and the runtime stays terminally frozen.

local Assert = require("tests.support.Assert")
local FieldSave = require("libs.engine.src.FieldSave")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "start-menu", "application", "transition", "hgss" },
  },
  tests = {},
}

local FAKE_DESTINATION = "fake_destination"
local TRAINER_CARD_REF = "msg.hgss.0196.00003"
local FACTORY_FAILURE_TEXT = "acceptance injected destination factory failure"

-- The fake destination rides a mod Start Menu action after the production
-- trainer card, so the production card and the fake are both visible and the
-- journey can launch the fake (whose disposal counter is observable).
local FAKE_ACTION = "my_mod.fake_destination"
local FAKE_ACTION_REF = "msg.hgss.0542.00034"

-- The §17.1 minimal controller contract a destination factory must return:
-- updateFixed(uiInput) mutates pure logical state, status() is presentation
-- data, takeResult() returns at most one { kind = "close"|"launch" } result,
-- and dispose() releases the logical lifetime idempotently. The fake closes
-- on the cancel edge so the host return path runs through the real input
-- pipeline; counters make exactly-once stepping and disposal observable.
local function fakeDestinationController()
  local controller = {
    updateFixedCalls = 0,
    disposeCount = 0,
    _result = nil,
    _closed = false,
  }
  function controller:updateFixed(uiInput)
    self.updateFixedCalls = self.updateFixedCalls + 1
    if self._closed then
      return
    end
    for _, event in ipairs(uiInput) do
      if event.type == "cancel" then
        self._result = { kind = "close" }
        self._closed = true
      end
    end
  end
  function controller:status()
    return { open = not self._closed, label = "fake destination", calls = self.updateFixedCalls }
  end
  function controller:takeResult()
    local result = self._result
    self._result = nil
    if result ~= nil then
      self._closed = true
    end
    return result
  end
  function controller:dispose()
    self.disposeCount = self.disposeCount + 1
    self._result = nil
    self._closed = true
  end
  return controller
end

local function hostStatus(game)
  local host = game.runtime.applicationHost
  ---@diagnostic disable-next-line: undefined-field -- the runtime application-host surface is the contract under test
  return host:status()
end

local function hostPhase(game)
  return hostStatus(game).phase
end

local function audioEffects(game)
  local entries = {}
  for _, entry in ipairs(game.hosts.effects) do
    if type(entry) == "string" and entry:sub(1, 6) == "audio:" then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

local function menuActions(game)
  local status = hostStatus(game)
  return status.menu and status.menu.actions or {}
end

local function actionById(actions, id)
  for _, action in ipairs(actions) do
    if action.id == id then
      return action
    end
  end
  return nil
end

local function scriptFaults(game)
  local faults = {}
  for _, record in ipairs(game.hosts.events.records) do
    if record.name == "script.error" then
      faults[#faults + 1] = record
    end
  end
  return faults
end

-- The menu-key open edge through the production input pipeline: press, one
-- fixed tick, release. The session's application-host check consumes the
-- edge at the idle boundary; the host begins ownership (beginUi flushes the
-- opening edge so it cannot immediately close the menu it opened).
local function pressMenuEdge(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
end

-- Bounded wait on the host phase; fixed tick counts are never asserted for
-- fade durations (the spec pins the phase sequence, not the fade length).
local function advanceToPhase(game, phase, maxTicks)
  return game:advanceUntil("start menu reaches " .. phase, function()
    return hostPhase(game) == phase
  end, maxTicks)
end

local function assertPausedAt(player, game, label)
  local snapshot = game:snapshot()
  Assert.equal(snapshot.player.fieldX, player.fieldX, label .. " must keep the world paused (fieldX)")
  Assert.equal(snapshot.player.fieldZ, player.fieldZ, label .. " must keep the world paused (fieldZ)")
  Assert.equal(snapshot.player.motion, "idle", label .. " must keep the player idle")
end

function T.tests.start_menu_lifecycle_with_a_registered_destination_runs_through_production_composition()
  local fake ---@type any
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      applicationDescriptors = {
        {
          id = FAKE_DESTINATION,
          factory = function()
            fake = fakeDestinationController()
            return fake
          end,
        },
      },
      startMenuDescriptors = {
        {
          id = FAKE_ACTION,
          label = FAKE_ACTION_REF,
          icon = "asset.my_mod.fake_destination_icon",
          targetApplication = FAKE_DESTINATION,
          placement = { after = "vanilla.trainer_card" },
        },
      },
    },
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    ---@diagnostic disable-next-line: undefined-field -- the runtime application-registry surface is the contract under test
    local applications = runtime.applications
    Assert.isTrue(
      type(applications) == "table",
      "the production runtime must expose the sealed application registry, got: " .. tostring(applications)
    )
    ---@diagnostic disable-next-line: need-check-nil -- asserted by the preceding isTrue contract
    Assert.equal(applications.sealed, true, "the application registry must be sealed once populated")
    Assert.isTrue(type(applications.has) == "function", "the application registry must answer application-id queries")
    ---@diagnostic disable-next-line: need-check-nil -- asserted by the preceding isTrue contract
    Assert.equal(applications:has("start_menu"), true, "the start_menu factory must be registered before the seal")
    Assert.equal(
      applications:has(FAKE_DESTINATION),
      true,
      "a boot-config application descriptor must populate the registry before the seal"
    )
    ---@diagnostic disable-next-line: undefined-field -- the runtime application-host surface is the contract under test
    local applicationHost = runtime.applicationHost ---@type any
    Assert.isTrue(
      type(applicationHost) == "table" and type(applicationHost.status) == "function",
      "the production runtime must expose the application host"
    )
    Assert.equal(hostPhase(game), "closed", "the host starts closed")
    Assert.equal(hostStatus(game).fadeAlpha, 0, "no application fade is active at the closed boundary")

    -- Ineligible open edge: a menu press mid-walk must be ignored without
    -- acquiring focus or the movement pause; the walk completes normally and
    -- the ignored edge cannot poison the next open.
    local beforeWalk = game:snapshot()
    runtime:press("west")
    game:step()
    Assert.equal(
      game:snapshot().player.motion,
      "walking",
      "the player must be mid-walk before the ineligible menu press"
    )
    runtime:pressMenu()
    game:step()
    runtime:releaseMenu()
    runtime:release("west")
    game:advanceUntil("the walk completes", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 24)
    local afterWalk = game:snapshot()
    Assert.equal(hostPhase(game), "closed", "an ineligible menu edge must not open the start menu")
    Assert.equal(
      afterWalk.player.fieldX,
      beforeWalk.player.fieldX - 1,
      "the ignored menu edge must not interrupt the walk"
    )

    -- The eligible open at the settled field boundary: the menu-key edge
    -- opens the menu and consumes the tick.
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    Assert.equal(hostStatus(game).fadeAlpha, 0, "opening the menu applies no application fade")
    Assert.equal(FieldSave.canCapture(game.runtime.session), false, "the open menu must block save capture")
    local menu = hostStatus(game).menu ---@type any
    Assert.isTrue(type(menu) == "table" and menu.open == true, "the host must present the open start menu")
    local actions = menuActions(game)
    Assert.equal(#actions, 2, "the production trainer card and the mod fake destination are both visible")
    local card = actionById(actions, "vanilla.trainer_card") ---@type any
    Assert.notNil(card, "the trainer card action must be visible once its destination is registered")
    Assert.equal(card.enabled, true, "the registered destination must enable its action")
    Assert.equal(card.position, 0, "the trainer card is the first present action of a fresh game")
    Assert.equal(card.slotId, 2, "display position 0 occupies manifest slot 2")
    Assert.equal(card.targetApplication, "trainer_card", "the action must target the production trainer card")
    Assert.isTrue(
      type(card.message) == "string" and card.message ~= "" and card.message ~= TRAINER_CARD_REF,
      "the composition step must resolve the action label through the message provider"
    )
    local fakeAction = actionById(actions, FAKE_ACTION) ---@type any
    Assert.notNil(fakeAction, "the mod fake action must be visible after the trainer card")
    Assert.equal(fakeAction.enabled, true, "the fake destination must enable its action")
    Assert.equal(fakeAction.position, 1, "the mod action occupies the next display position")
    Assert.equal(fakeAction.slotId, 3, "display position 1 occupies manifest slot 3")
    Assert.equal(menu.cursorSlotId, 2, "the fresh menu selects the first enabled action")
    Assert.equal(#audioEffects(game), 1, "opening the menu must request exactly the open sound")
    local pausedAtOpen = game:snapshot().player
    -- The pause check doubles as the selection move: with exactly two visible
    -- actions a south move navigates the wrap-around list to the mod fake
    -- action (slot 3), which the round trip must then restore by action id.
    game:move("south")
    assertPausedAt(pausedAtOpen, game, "the open menu")
    Assert.equal(hostStatus(game).menu.cursorSlotId, 3, "the move navigates the menu to the fake destination action")

    -- Confirm: the select sound fires once, then the fade-out ticks run and
    -- the destination is constructed through the registry factory only after
    -- the fade hides the world.
    runtime:pressAction()
    game:step()
    runtime:releaseAction()
    Assert.equal(#audioEffects(game), 2, "confirming must request exactly the select sound")
    advanceToPhase(game, "fading_out", 8)
    Assert.isTrue(hostStatus(game).fadeAlpha < 1, "the fade-out must be in progress while the fade phase is active")
    advanceToPhase(game, "application", 64)
    Assert.equal(hostStatus(game).fadeAlpha, 1, "the application phase must run fully faded out")
    Assert.equal(hostStatus(game).applicationId, FAKE_DESTINATION, "the host must name the active destination")
    Assert.notNil(fake, "the destination must be constructed through the registered factory")
    Assert.isTrue(
      fake.updateFixedCalls >= 1,
      "the host must step the active destination controller once per fixed tick"
    )
    assertPausedAt(pausedAtOpen, game, "the child application")
    game:move("north")
    assertPausedAt(pausedAtOpen, game, "the child application")
    Assert.equal(FieldSave.canCapture(game.runtime.session), false, "the active application must block save capture")

    -- The destination closes on its cancel edge; the host disposes it
    -- exactly once, rebuilds the menu, and restores the remembered
    -- selection by action id.
    runtime:pressCancel()
    game:step()
    runtime:releaseCancel()
    advanceToPhase(game, "fading_in", 64)
    Assert.equal(fake.disposeCount, 1, "the returned destination must be disposed exactly once")
    advanceToPhase(game, "menu", 64)
    Assert.equal(fake.disposeCount, 1, "the destination must never be disposed twice")
    Assert.equal(#audioEffects(game), 3, "the menu rebuild must request the open sound again")
    local rebuiltMenu = hostStatus(game).menu ---@type any
    Assert.equal(
      rebuiltMenu.cursorSlotId,
      3,
      "the rebuild must restore the remembered fake destination selection by action id"
    )
    assertPausedAt(pausedAtOpen, game, "the rebuilt menu")

    -- The menu-key close: the cancel sound fires once, the host returns to
    -- the field, the save boundary restores, and the closing edges leak
    -- nothing into field interaction or movement.
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    Assert.equal(#audioEffects(game), 4, "closing the menu must request exactly the cancel sound")
    Assert.equal(
      FieldSave.canCapture(game.runtime.session),
      true,
      "the settled field boundary must allow capture again"
    )
    assertPausedAt(pausedAtOpen, game, "the closed menu")
    Assert.equal(game:snapshot().dialogue.modal, false, "the closing edge must not open any field dialogue")
    Assert.equal(#scriptFaults(game), 0, "the lifecycle must run without script faults")
    game:step()
    Assert.equal(hostPhase(game), "closed", "the closing menu edge must not reopen the menu")
    Assert.equal(game:snapshot().dialogue.modal, false, "the menu-key release must not trigger a field interaction")

    -- Runtime disposal while the menu owns the tick: the transient save gate
    -- holds at disposal, the exactly-once destination disposal is not
    -- repeated, and the teardown releases cleanly.
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    game:close()
    Assert.equal(game.saveStatus:find("Save deferred", 1, true) ~= nil, true, "disposal mid-menu must defer the save")
    Assert.equal(fake.disposeCount, 1, "runtime disposal must not re-dispose a returned destination")
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the application lifecycle must not render")
  game:close()
end

function T.tests.development_menu_disables_capability_missing_actions_and_a_destination_factory_failure_is_retained()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      development = true,
      applicationDescriptors = {
        {
          id = FAKE_DESTINATION,
          factory = function()
            error(FACTORY_FAILURE_TEXT, 0)
          end,
        },
      },
      startMenuDescriptors = {
        {
          id = FAKE_ACTION,
          label = FAKE_ACTION_REF,
          icon = "asset.my_mod.fake_destination_icon",
          targetApplication = FAKE_DESTINATION,
          placement = { after = "vanilla.trainer_card" },
        },
      },
    },
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    ---@diagnostic disable-next-line: undefined-field -- the runtime application-registry surface is the contract under test
    local applications = runtime.applications
    Assert.isTrue(
      type(applications) == "table",
      "the production runtime must expose the sealed application registry, got: " .. tostring(applications)
    )
    Assert.equal(
      applications:has(FAKE_DESTINATION),
      true,
      "a boot-config application descriptor must populate the registry before the seal"
    )
    Assert.equal(hostPhase(game), "closed", "the host starts closed")

    -- Developer mode renders capability-missing canonical entries in a
    -- disabled state (§20: developerVisible = present), while entries the
    -- vanilla policy itself withholds stay absent.
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local actions = menuActions(game)
    Assert.equal(#actions, 7, "developer mode must show every present canonical action plus the mod action")
    local save = actionById(actions, "vanilla.save") ---@type any
    Assert.notNil(save, "the save action must be visible in developer mode")
    Assert.equal(save.enabled, false, "a capability-missing canonical action must render disabled in developer mode")
    local specialNine = actionById(actions, "vanilla.special_9") ---@type any
    Assert.notNil(specialNine, "the pokégear-family special action must be visible in developer mode")
    Assert.equal(
      specialNine.enabled,
      false,
      "a capability-missing special action must render disabled in developer mode"
    )
    Assert.isNil(actionById(actions, "vanilla.pokedex"), "a vanilla-withheld action must stay absent in developer mode")
    local card = actionById(actions, "vanilla.trainer_card") ---@type any
    Assert.notNil(card, "the production destination action must be visible in developer mode")
    Assert.equal(card.enabled, true, "the production destination must enable its action")
    local fakeAction = actionById(actions, FAKE_ACTION) ---@type any
    Assert.notNil(fakeAction, "the mod fake action must be visible in developer mode")
    Assert.equal(fakeAction.enabled, true, "the fake destination must enable its action")
    local devMenu = hostStatus(game).menu ---@type any
    Assert.equal(devMenu.cursorSlotId, 2, "the developer menu selects the first enabled action")

    -- Navigate to the mod action whose factory raises, then confirm: the
    -- destination factory fails after the fade-out hides the world, the
    -- original error is retained, no successful return to the menu is
    -- reported, and the runtime freezes terminally.
    game.runtime.input:pressDirection("south", "test:navigate")
    game:step()
    game.runtime.input:releaseDirection("test:navigate")
    Assert.equal(hostStatus(game).menu.cursorSlotId, 3, "navigating selects the failing fake destination action")
    runtime:pressAction()
    game:step()
    runtime:releaseAction()
    game:advanceUntil("the destination factory failure is retained", function()
      return runtime.errorText ~= nil
    end, 96)
    Assert.isTrue(
      runtime.errorText:find(FACTORY_FAILURE_TEXT, 1, true) ~= nil,
      "the retained error must carry the original factory failure, got: " .. tostring(runtime.errorText)
    )
    local phase = hostPhase(game)
    Assert.isTrue(
      phase ~= "menu" and phase ~= "closed",
      "a failed destination factory must not report a successful return to the menu, phase: " .. tostring(phase)
    )
    local frozen = game:snapshot()
    game:step()
    game:step()
    Assert.equal(
      game:snapshot().tick,
      frozen.tick,
      "the failed runtime must freeze instead of resuming field simulation"
    )
    assertPausedAt(frozen.player, game, "the failed runtime")
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the failure path must not render")
  game:close()
end

return T
