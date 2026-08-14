-- Production-composed Trainer Card viewer contract: the runtime itself must
-- register the real trainer_card application (no boot-config descriptor), the
-- card's presentation must reach the host snapshot carrying the authoritative
-- player profile (name/gender/trainerId from runtime.playerData through the
-- read model), and the full journey Start Menu → card → cancel → Start Menu
-- must run with the world paused, the save gate blocked, and the card's close
-- edge leaking nothing into the field. One production boot in normal mode:
-- the vanilla trainer_card action is enabled exactly because the production
-- destination exists, confirming the card and the select sound fire once, the
-- application phase presents only the card surface, and the close plays the
-- card's cancel effect (source: overlay_trainer_card_main.s ov51_021E6A54 at
-- the pinned decomp commit — B plays SEQ_SE_GS_GEARCANCEL and returns the
-- close state). The menu rebuild restores the remembered selection; the final
-- menu close returns to a capturable field with zero script faults.

local Assert = require("tests.support.Assert")
local FieldSave = require("libs.engine.src.FieldSave")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "start-menu", "application", "trainer-card", "hgss" },
  },
  tests = {},
}

local CARD_APPLICATION = "trainer_card"

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
-- edge at the idle boundary.
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

function T.tests.trainer_card_viewer_runs_through_production_composition_and_returns_to_the_start_menu()
  local harness = AcceptanceHarness.new()
  local game = harness:boot({
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
      "the production runtime must expose the sealed application registry, got: " .. tostring(applications)
    )
    ---@diagnostic disable-next-line: undefined-field -- the runtime player-data surface is the contract under test
    local profile = runtime.playerData.profile
    Assert.isTrue(
      type(profile) == "table" and type(profile.name) == "string",
      "the runtime must expose the authoritative player profile"
    )
    Assert.equal(
      applications:has(CARD_APPLICATION),
      true,
      "the production runtime must register the trainer_card application without a boot-config descriptor"
    )
    Assert.equal(hostPhase(game), "closed", "the host starts closed")
    Assert.equal(hostStatus(game).fadeAlpha, 0, "no application fade is active at the closed boundary")

    -- The vanilla trainer_card action is enabled in normal mode exactly
    -- because the production destination exists (§20 capability formula).
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local actions = menuActions(game)
    Assert.equal(#actions, 1, "normal mode must show only the capability-available trainer card action")
    local card = actions[1]
    Assert.notNil(card, "the trainer card action must be present")
    Assert.equal(card.id, "vanilla.trainer_card", "the first visible action is the trainer card")
    Assert.equal(card.targetApplication, CARD_APPLICATION, "the action must target the trainer card application")
    Assert.equal(card.enabled, true, "the production destination must enable the action")
    Assert.equal(hostStatus(game).menu.cursorSlotId, 2, "the fresh menu selects the first enabled action")
    Assert.equal(hostStatus(game).application, nil, "the menu phase must present only the menu surface")
    Assert.equal(#audioEffects(game), 1, "opening the menu must request exactly the open sound")
    local pausedAtOpen = game:snapshot().player
    assertPausedAt(pausedAtOpen, game, "the open menu")

    -- Confirm: the select sound fires once, then the fade-out runs and the
    -- card is constructed as the active application after the world hides.
    runtime:pressAction()
    game:step()
    runtime:releaseAction()
    Assert.equal(#audioEffects(game), 2, "confirming must request exactly the select sound")
    advanceToPhase(game, "fading_out", 8)
    Assert.isTrue(hostStatus(game).fadeAlpha < 1, "the fade-out must be in progress while the fade phase is active")
    advanceToPhase(game, "application", 64)
    Assert.equal(hostStatus(game).fadeAlpha, 1, "the application phase must run fully faded out")
    Assert.equal(hostStatus(game).applicationId, CARD_APPLICATION, "the host must name the active card application")
    Assert.equal(hostStatus(game).menu, nil, "the card phase must present only the card surface")

    -- The card presentation carries the authoritative profile: the read-only
    -- viewer must project runtime.playerData, never renderer constants or
    -- fabricated card values.
    local application = hostStatus(game).application
    Assert.isTrue(
      type(application) == "table",
      "the host snapshot must present the active card application, got: " .. tostring(application)
    )
    Assert.equal(
      application.name,
      profile.name,
      "the card must present the authoritative player name, got: " .. tostring(application and application.name)
    )
    Assert.equal(
      application.gender,
      profile.gender,
      "the card must present the authoritative player gender, got: " .. tostring(application and application.gender)
    )
    Assert.equal(
      application.trainerId,
      profile.trainerId,
      "the card must present the authoritative trainer id, got: " .. tostring(application and application.trainerId)
    )
    Assert.equal(FieldSave.canCapture(runtime.session), false, "the active card must block save capture")
    assertPausedAt(pausedAtOpen, game, "the active card")

    -- No field input while the card is active: movement and the action edge
    -- must neither move the player nor open any field interaction.
    game:move("north")
    assertPausedAt(pausedAtOpen, game, "the card under a movement edge")
    game:pressAction()
    Assert.equal(hostPhase(game), "application", "the action edge must not dismiss the card")
    Assert.equal(
      game:snapshot().dialogue.modal,
      false,
      "the action edge must not open field dialogue while the card is active"
    )
    Assert.equal(hostStatus(game).application.name, profile.name, "the card must stay open under foreign input")

    -- Cancel closes the card: its close edge plays the cancel effect and the
    -- host returns to the rebuilt Start Menu with the remembered selection.
    runtime:pressCancel()
    game:step()
    runtime:releaseCancel()
    advanceToPhase(game, "fading_in", 64)
    Assert.equal(#audioEffects(game), 3, "closing the card must request exactly the cancel sound")
    advanceToPhase(game, "menu", 64)
    Assert.equal(#audioEffects(game), 4, "the menu rebuild must request the open sound again")
    Assert.equal(hostStatus(game).menu.cursorSlotId, 2, "the rebuild must restore the trainer card selection")
    Assert.equal(hostStatus(game).application, nil, "the rebuilt menu must present only the menu surface")
    assertPausedAt(pausedAtOpen, game, "the rebuilt menu")

    -- The menu-key close returns to a capturable field; the closing edges
    -- leak nothing into field interaction or movement.
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    Assert.equal(#audioEffects(game), 5, "closing the menu must request exactly the cancel sound")
    Assert.equal(FieldSave.canCapture(runtime.session), true, "the settled field boundary must allow capture again")
    Assert.equal(game:snapshot().dialogue.modal, false, "the closing edge must not open any field dialogue")
    Assert.equal(#scriptFaults(game), 0, "the card journey must run without script faults")
    game:step()
    Assert.equal(hostPhase(game), "closed", "the closing menu edge must not reopen the menu")
    Assert.equal(game:snapshot().dialogue.modal, false, "the menu-key release must not trigger a field interaction")
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the trainer card viewer must not render")
  game:close()
end

return T
