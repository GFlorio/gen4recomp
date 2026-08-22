-- Production-composed Trainer Card lifecycle journey through the real
-- application host: no boot-config descriptor injection -- the vanilla
-- trainer card becomes interactive exactly because its unlock flag is set
-- and the production destination exists. One boot walks the production
-- journey: an ineligible open edge mid-walk acquires nothing and does not
-- interrupt the walk; the menu opens at an idle boundary with save capture
-- blocked; the visible trainer card action confirms through the fade to the
-- production card (world paused, save still blocked, the card presents the
-- authoritative player profile and stays open under foreign field input);
-- cancel returns through the fade to the rebuilt menu; the menu-key close
-- restores the capturable field boundary with zero script faults and field
-- simulation resumes. The UI-owned audio stack is removed, so every menu
-- boundary -- open, confirm, rebuild, close -- must be silent: no sound
-- request may reach the recording audio seam. Phase-machine details (fade
-- tick counts, registry plumbing, selection slot numbers, presentation key
-- sets, disposal counters) live in the FieldApplicationHost /
-- StartMenuController / FieldState unit and component suites; this journey
-- asserts only the user-visible modal surfaces and field boundary.

local Assert = require("tests.support.Assert")
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
local CARD_ACTION = "vanilla.trainer_card"

local function hostStatus(game)
  local host = game.runtime.applicationHost
  ---@diagnostic disable-next-line: undefined-field -- the runtime application-host surface is the contract under test
  return host:status()
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

-- Semantic waits on the modal surfaces, never on host phase names or fade
-- tick counters: the start menu surface exists, the card surface exists, or
-- the field save gate is open again. The fade between them is host-owned
-- visual state (unit-tested) and unobservable under the render trap.
local function waitForMenu(game, maxTicks)
  return game:advanceUntil("the start menu opens", function()
    return hostStatus(game).menu ~= nil
  end, maxTicks)
end

local function waitForCard(game, maxTicks)
  return game:advanceUntil("the trainer card opens", function()
    return hostStatus(game).application ~= nil
  end, maxTicks)
end

local function waitForFieldBoundary(game, maxTicks)
  return game:advanceUntil("the field boundary restores", function()
    return game.runtime:captureGameSave() ~= nil
  end, maxTicks)
end

local function assertPausedAt(player, game, label)
  local snapshot = game:snapshot()
  Assert.equal(snapshot.player.fieldX, player.fieldX, label .. " must keep the world paused (fieldX)")
  Assert.equal(snapshot.player.fieldZ, player.fieldZ, label .. " must keep the world paused (fieldZ)")
  Assert.equal(snapshot.player.motion, "idle", label .. " must keep the player idle")
end

-- The whole production application lifecycle in one boot, through the real
-- Trainer Card destination: the vanilla card becomes interactive exactly
-- because its unlock flag is set and the production destination exists, and
-- the journey opens, blocks save capture, launches the card, presents the
-- authoritative profile, stays open under foreign field input, returns
-- through the fade to the rebuilt menu, closes, and restores the field
-- boundary with zero script faults.
function T.tests.the_production_trainer_card_journey_runs_without_injected_application_descriptors()
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    Assert.equal(
      runtime:captureGameSave() ~= nil,
      true,
      "the fresh field boundary must be capturable before any modal opens"
    )

    -- Ineligible open edge: a menu press mid-walk must be ignored without
    -- opening any menu surface or pausing the walk; the walk completes
    -- normally and the ignored edge cannot poison the next open.
    local beforeWalk = game:snapshot()
    runtime:press("west")
    game:step()
    Assert.equal(
      game:snapshot().player.motion,
      "walking",
      "the player must be mid-walk before the ineligible menu press"
    )
    pressMenuEdge(game)
    runtime:release("west")
    game:advanceUntil("the walk completes", function(snapshot)
      return snapshot.player.motion == "idle"
    end, 24)
    local afterWalk = game:snapshot()
    Assert.equal(hostStatus(game).menu, nil, "an ineligible menu edge must not open the start menu")
    Assert.equal(
      afterWalk.player.fieldX,
      beforeWalk.player.fieldX - 1,
      "the ignored menu edge must not interrupt the walk"
    )
    Assert.isTrue(runtime:captureGameSave() ~= nil, "the completed walk must be capturable again")

    -- The real unlock flag makes the trainer card interactive; the eligible
    -- open at the settled field boundary opens the menu and consumes the
    -- tick, blocking save capture.
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    pressMenuEdge(game)
    waitForMenu(game, 16)
    Assert.isNil(runtime:captureGameSave(), "the open menu must block save capture")
    local actions = menuActions(game)
    local enabledActions = {}
    for _, action in ipairs(actions) do
      if action.enabled then
        enabledActions[#enabledActions + 1] = action
      end
    end
    Assert.equal(#enabledActions, 1, "the unlocked trainer card must be the only enabled interactive destination")
    Assert.equal(enabledActions[1].id, CARD_ACTION, "the enabled action must be the production trainer card")
    Assert.equal(
      enabledActions[1].targetApplication,
      CARD_APPLICATION,
      "the action must target the production trainer card"
    )
    Assert.equal(#audioEffects(game), 0, "opening the menu must not request any UI sound")
    local pausedAtOpen = game:snapshot().player
    assertPausedAt(pausedAtOpen, game, "the open menu")

    -- Confirm: no select sound fires, and the production card is constructed
    -- through the registry factory after the fade hides the world. The card
    -- presents the authoritative player profile and keeps the save gate
    -- blocked.
    runtime:pressAction()
    game:step()
    runtime:releaseAction()
    Assert.equal(#audioEffects(game), 0, "confirming must not request any UI sound")
    waitForCard(game, 64)
    ---@diagnostic disable-next-line: undefined-field -- the runtime player-data surface is the contract under test
    local profile = runtime.playerData.profile
    local application = hostStatus(game).application ---@type any
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
    Assert.isNil(runtime:captureGameSave(), "the active card must block save capture")
    assertPausedAt(pausedAtOpen, game, "the active card")

    -- Foreign field input while the card owns the modal: movement edges
    -- neither move the player nor open a field interaction, and the action
    -- edge cannot dismiss the card.
    game:move("north")
    assertPausedAt(pausedAtOpen, game, "the card under a movement edge")
    game:pressAction()
    Assert.equal(hostStatus(game).application ~= nil, true, "the action edge must not dismiss the card")
    Assert.equal(
      game:snapshot().dialogue.modal,
      false,
      "the action edge must not open field dialogue while the card is active"
    )
    Assert.equal(hostStatus(game).application.name, profile.name, "the card must stay open under foreign input")

    -- The card closes on its cancel edge; the host disposes it and rebuilds
    -- the menu (the selection restore is the host-unit contract).
    runtime:pressCancel()
    game:step()
    runtime:releaseCancel()
    Assert.equal(#audioEffects(game), 0, "closing the card must not request any UI sound")
    waitForMenu(game, 64)
    Assert.equal(#audioEffects(game), 0, "the menu rebuild must not request any UI sound")
    local rebuilt = menuActions(game)
    local rebuiltEnabled = {}
    for _, action in ipairs(rebuilt) do
      if action.enabled then
        rebuiltEnabled[#rebuiltEnabled + 1] = action
      end
    end
    Assert.equal(#rebuiltEnabled, 1, "the rebuilt menu must have the trainer card as the only enabled action")
    Assert.equal(
      rebuiltEnabled[1].id,
      CARD_ACTION,
      "the rebuilt enabled action must still be the production trainer card"
    )
    assertPausedAt(pausedAtOpen, game, "the rebuilt menu")

    -- The menu-key close: no cancel sound fires, the host returns to the
    -- field, the save boundary restores, and the closing edges leak nothing
    -- into field interaction or movement.
    pressMenuEdge(game)
    waitForFieldBoundary(game, 16)
    Assert.equal(#audioEffects(game), 0, "closing the menu must not request any UI sound")
    Assert.equal(game:snapshot().dialogue.modal, false, "the closing edge must not open any field dialogue")
    Assert.equal(#scriptFaults(game), 0, "the lifecycle must run without script faults")
    game:step()
    Assert.equal(hostStatus(game).menu, nil, "the closing menu edge must not reopen the menu")
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
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the application lifecycle must not render")
  game:close()
end

return T
