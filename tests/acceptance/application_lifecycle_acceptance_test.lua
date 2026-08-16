-- Production-composed application host lifecycle contract through the real
-- Trainer Card destination: the runtime registers the production card with
-- no boot-config descriptor injection, and the normal-field menu policy
-- reads the real unlock flags -- a destination becomes interactive exactly
-- when present AND unlocked AND registered. One boot walks the full
-- production journey: an ineligible open edge mid-walk acquires nothing and
-- does not interrupt the walk, the menu opens at an idle boundary with save
-- capture blocked, the visible trainer card action confirms through the
-- fade to the production TrainerCardController (world paused, save still
-- blocked), cancel returns through the fade to the rebuilt menu with the
-- remembered selection, the menu-key close restores the capturable field
-- boundary with zero script faults, field simulation resumes, and runtime
-- disposal mid-menu releases the modal before the save attempt. The
-- UI-owned audio stack is removed, so every menu boundary -- open, select,
-- rebuild, close -- must be silent: no sound request may reach the
-- recording audio seam. The second scenario pins the zero-action no-op:
-- with no unlock flag set the menu press opens nothing, acquires no UI
-- lifetime, and the field continues; the same edge opens the menu once the
-- trainer card is unlocked.

local Assert = require("tests.support.Assert")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "start-menu", "application", "transition", "hgss" },
  },
  tests = {},
}

local CARD_APPLICATION = "trainer_card"

local UNLOCK_FLAGS = {
  FieldScriptSymbols.flagsByName.FLAG_GOT_POKEDEX,
  FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER,
  FieldScriptSymbols.flagsByName.FLAG_GOT_BAG,
  FieldScriptSymbols.flagsByName.FLAG_GOT_POKEGEAR,
  FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD,
  FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON,
  FieldScriptSymbols.flagsByName.FLAG_GOT_OPTIONS_BUTTON,
}

local function hostStatus(game)
  local host = game.runtime.applicationHost
  ---@diagnostic disable-next-line: undefined-field -- the runtime application-host surface is the contract under test
  return host:status()
end

local function hostPhase(game)
  return hostStatus(game).phase
end

local function audioEffects(game)
  -- The recording audio seam is the contract observer: with the UI-owned
  -- audio stack deleted, every menu boundary must leave zero entries here.
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
-- fixed tick, release. The session's open gate consumes the edge at the
-- idle boundary.
local function pressMenuEdge(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
end

-- Bounded wait on the host phase; fixed tick counts are never asserted for
-- fade durations (the host owns the fade length; the phase sequence is its
-- own contract).
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

-- The whole production application lifecycle in one boot, through the real
-- Trainer Card destination: no application descriptor is injected, the
-- vanilla trainer card becomes interactive exactly because its unlock flag
-- is set and the production destination exists, and the journey opens,
-- blocks save capture, launches the card through the production registry
-- factory, returns through the fade to the remembered selection, closes,
-- and restores the field boundary.
function T.tests.the_production_trainer_card_journey_runs_without_injected_application_descriptors()
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    ---@diagnostic disable-next-line: undefined-field -- the runtime application-registry surface is the contract under test
    local applications = runtime.applications
    Assert.isTrue(
      type(applications) == "table",
      "the production runtime must expose the application registry, got: " .. tostring(applications)
    )
    Assert.equal(
      applications:has(CARD_APPLICATION),
      true,
      "the production runtime must register the trainer card without a boot-config descriptor"
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

    -- The real unlock flag makes the trainer card interactive; the eligible
    -- open at the settled field boundary opens the menu and consumes the
    -- tick.
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    Assert.equal(hostStatus(game).fadeAlpha, 0, "opening the menu applies no application fade")
    Assert.equal(FieldSave.canCapture(runtime.session), false, "the open menu must block save capture")
    local menu = hostStatus(game).menu ---@type any
    Assert.isTrue(type(menu) == "table" and menu.open == true, "the host must present the open start menu")
    local actions = menuActions(game)
    Assert.equal(#actions, 1, "the unlocked trainer card must be the only interactive destination")
    local card = actions[1]
    Assert.equal(card.id, "vanilla.trainer_card", "the visible action must be the production trainer card")
    Assert.isNil(card.message, "the start menu carries no resolved label text")
    Assert.isNil(card.enabled, "the final action list carries no product-mode projection")
    Assert.equal(card.targetApplication, CARD_APPLICATION, "the action must target the production trainer card")
    Assert.equal(menu.cursorSlotId, 2, "the fresh menu selects the first enabled action")
    Assert.equal(#audioEffects(game), 0, "opening the menu must not request any UI sound")
    local pausedAtOpen = game:snapshot().player
    assertPausedAt(pausedAtOpen, game, "the open menu")

    -- Confirm: no select sound fires, then the fade-out ticks run and the
    -- production TrainerCardController is constructed through the registry
    -- factory only after the fade hides the world.
    runtime:pressAction()
    game:step()
    runtime:releaseAction()
    Assert.equal(#audioEffects(game), 0, "confirming must not request any UI sound")
    advanceToPhase(game, "fading_out", 8)
    Assert.isTrue(hostStatus(game).fadeAlpha < 1, "the fade-out must be in progress while the fade phase is active")
    advanceToPhase(game, "application", 64)
    Assert.equal(hostStatus(game).fadeAlpha, 1, "the application phase must run fully faded out")
    Assert.equal(hostStatus(game).applicationId, CARD_APPLICATION, "the host must name the active card application")
    Assert.isNil(hostStatus(game).menu, "the card phase must present only the card surface")
    ---@diagnostic disable-next-line: undefined-field -- the runtime player-data surface is the contract under test
    local profile = runtime.playerData.profile
    local application = hostStatus(game).application ---@type any
    Assert.isTrue(
      type(application) == "table",
      "the host snapshot must present the active card application, got: " .. tostring(application)
    )
    Assert.equal(
      application.name,
      profile.name,
      "the production card must present the authoritative player name, got: "
        .. tostring(application and application.name)
    )
    Assert.equal(
      application.trainerId,
      profile.trainerId,
      "the production card must present the authoritative trainer id, got: "
        .. tostring(application and application.trainerId)
    )
    Assert.equal(FieldSave.canCapture(runtime.session), false, "the active card must block save capture")
    assertPausedAt(pausedAtOpen, game, "the active card")

    -- The card closes on its cancel edge; the host disposes it, rebuilds
    -- the menu, and restores the remembered selection.
    runtime:pressCancel()
    game:step()
    runtime:releaseCancel()
    advanceToPhase(game, "fading_in", 64)
    advanceToPhase(game, "menu", 64)
    Assert.equal(#audioEffects(game), 0, "the menu rebuild must not request any UI sound")
    Assert.equal(
      hostStatus(game).menu.cursorSlotId,
      2,
      "the rebuild must restore the remembered trainer card selection by action id"
    )
    assertPausedAt(pausedAtOpen, game, "the rebuilt menu")

    -- The menu-key close: no cancel sound fires, the host returns to the
    -- field, the save boundary restores, and the closing edges leak nothing
    -- into field interaction or movement.
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    Assert.equal(#audioEffects(game), 0, "closing the menu must not request any UI sound")
    Assert.equal(FieldSave.canCapture(runtime.session), true, "the settled field boundary must allow capture again")
    assertPausedAt(pausedAtOpen, game, "the closed menu")
    Assert.equal(game:snapshot().dialogue.modal, false, "the closing edge must not open any field dialogue")
    Assert.equal(#scriptFaults(game), 0, "the lifecycle must run without script faults")
    game:step()
    Assert.equal(hostPhase(game), "closed", "the closing menu edge must not reopen the menu")
    Assert.equal(game:snapshot().dialogue.modal, false, "the menu-key release must not trigger a field interaction")

    -- The journey completes: the closed boundary resumes field simulation
    -- and movement works again.
    local resumedAt = game:snapshot()
    runtime:press("west")
    game:step()
    runtime:release("west")
    game:advanceUntil("the resumed walk completes", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 24)
    Assert.equal(
      game:snapshot().player.fieldX,
      resumedAt.player.fieldX - 1,
      "the field simulation must resume after the final menu close"
    )

    -- Runtime disposal while the menu owns the tick: the modal is released
    -- before the save attempt (the world persists like a mid-dialogue quit).
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    game:close()
    Assert.equal(
      game.saveStatus:find("Field session saved", 1, true) ~= nil,
      true,
      "disposal mid-menu must save the world: " .. tostring(game.saveStatus)
    )
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the application lifecycle must not render")
  game:close()
end

-- The zero-action no-op: with no unlock flag set the menu press must open
-- nothing -- the host stays closed, no controller is constructed, no modal
-- input lifetime is acquired, no failure is recorded, and the field keeps
-- simulating -- while the same open edge still opens the real menu once an
-- unlock flag makes a destination interactive. One boot proves both halves.
function T.tests.zero_action_menu_press_is_a_noop_and_the_field_continues()
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    local world = runtime.scripts.worldState

    -- The fixture precondition: a fresh boot seeds only scenario object
    -- flags, so every menu unlock flag starts unset.
    for _, flag in ipairs(UNLOCK_FLAGS) do
      Assert.equal(world:isFlagSet(flag), false, "the fresh boot must leave every menu unlock flag unset")
    end

    -- Zero interactive destinations: the menu edge is a no-op. The host
    -- stays closed and presents no menu surface, no UI lifetime is acquired,
    -- the save gate stays open, and no failure is recorded.
    pressMenuEdge(game)
    Assert.equal(hostPhase(game), "closed", "a zero-action menu press must not open a blank menu")
    Assert.equal(runtime.errorText, nil, "a zero-action menu press must not fail the runtime")
    Assert.equal(hostStatus(game).menu, nil, "a zero-action menu press must not present a menu surface")
    Assert.equal(runtime.input.uiActive, false, "a zero-action menu press must not acquire the modal input lifetime")
    Assert.equal(
      FieldSave.canCapture(runtime.session),
      true,
      "a zero-action menu press must leave the field capturable"
    )

    -- The field continues normally: the world keeps simulating and the
    -- player can still move.
    local before = game:snapshot()
    runtime:press("west")
    game:step()
    runtime:release("west")
    game:advanceUntil("the no-op walk completes", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 24)
    Assert.equal(
      game:snapshot().player.fieldX,
      before.player.fieldX - 1,
      "the field simulation must continue after the zero-action menu press"
    )

    -- The same open edge composes the real menu once a destination becomes
    -- interactive: unlocking the trainer card makes the next press open it.
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local actions = menuActions(game)
    Assert.equal(#actions, 1, "the unlocked trainer card must be the only interactive destination")
    Assert.equal(actions[1].id, "vanilla.trainer_card", "the unlocked destination must be the trainer card")
    Assert.equal(hostStatus(game).menu.cursorSlotId, 2, "the menu must select the unlocked trainer card")
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    Assert.equal(FieldSave.canCapture(runtime.session), true, "closing the menu must restore the capturable boundary")
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the zero-action contract must not render")
  game:close()
end

return T
