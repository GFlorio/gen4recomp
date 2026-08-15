-- Production-composed zero-action Start Menu contract: a fresh game whose
-- unlock flags are all unset must open a fully valid empty Start Menu (a
-- modal application with no selection, no cursor, inert navigation/confirm,
-- a live cancel region, and a healthy application host), close back to a
-- continuing field, and then — after FLAG_GOT_TRAINER_CARD is set — reopen
-- with the Trainer Card as the first interactive destination because that
-- application capability exists. The second boot pins the pointer half of
-- the empty contract on a canonical-size host where the placement is the
-- identity: action slots with no action are inert while the cancel region
-- still closes.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local ScreenTopology = require("libs.engine.src.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "start-menu", "application", "progression", "hgss" },
  },
  tests = {},
}

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

-- The menu-key open edge through the production input pipeline: press, one
-- fixed tick, release. The session's open gate consumes the edge at the
-- idle boundary.
local function pressMenuEdge(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
end

local function advanceToPhase(game, phase, maxTicks)
  return game:advanceUntil("start menu reaches " .. phase, function()
    return hostPhase(game) == phase
  end, maxTicks)
end

local function tapSlot(game, x, y)
  game.runtime.input:pointerDown("mouse:1", x, y)
  game:step()
  game.runtime.input:pointerUp("mouse:1", x, y)
  game:step()
end

-- A canonical-size single-display host (256x192): the Start Menu placement
-- is the identity, so the manifest's canonical slot rects are also the host
-- pointer coordinates, with no production transform reimplemented here.
local function canonicalTopology()
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 256, height = 192 },
    touch = true,
    role = "world",
  })
end

function T.tests.fresh_game_zero_action_start_menu_opens_and_closes_and_unlocking_trainer_card_changes_the_next_menu()
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

    -- The empty menu opens through the production composition: the host
    -- stays healthy (never failed), the menu is a modal application, and
    -- the presentation has no selection, no cursor, and no application id.
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    Assert.equal(runtime.errorText, nil, "the empty menu must not fail the application host")
    local menu = hostStatus(game).menu ---@type any
    Assert.isTrue(type(menu) == "table" and menu.open == true, "the empty start menu must open")
    Assert.equal(#menu.actions, 0, "no unlock flag with only the trainer_card capability must compose zero actions")
    Assert.equal(menu.cancelSlotId, 1, "the cancel region must remain the canonical slot 1")
    Assert.isNil(menu.cursorSlotId, "an empty menu must not select an action")
    Assert.isNil(menu.cursorFrameIndex, "an empty menu must not animate a cursor")
    Assert.isNil(hostStatus(game).applicationId, "an empty menu must not name a destination")
    Assert.equal(
      FieldSave.canCapture(runtime.session),
      false,
      "the empty menu must remain a modal application blocking the save gate"
    )

    -- Navigation on an empty list is a safe no-op.
    runtime.input:pressDirection("south", "test:navigate")
    game:step()
    runtime.input:releaseDirection("test:navigate")
    Assert.equal(hostPhase(game), "menu", "navigation must leave the empty menu open")
    Assert.equal(#hostStatus(game).menu.actions, 0, "navigation must not fabricate actions")

    -- Confirm on no selection records no result and stays open.
    runtime:pressAction()
    game:step()
    runtime:releaseAction()
    Assert.equal(hostPhase(game), "menu", "confirm must leave the empty menu open")
    Assert.equal(hostStatus(game).menu.open, true, "confirm must record no result on an empty menu")
    Assert.isNil(hostStatus(game).applicationId, "confirm must not launch anything from an empty menu")

    -- Cancel still closes; the field resumes on the next ticks.
    runtime:pressCancel()
    game:step()
    runtime:releaseCancel()
    advanceToPhase(game, "closed", 16)
    Assert.equal(FieldSave.canCapture(runtime.session), true, "the closed boundary must restore the save gate")
    local closed = game:snapshot()
    game:step()
    Assert.equal(game:snapshot().tick, closed.tick + 1, "the field simulation must continue after the empty menu")

    -- The real unlock changes the next composition: with the Trainer Card
    -- flag set, the card is the first interactive destination.
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local actions = hostStatus(game).menu.actions
    Assert.equal(#actions, 1, "the unlocked trainer card must be the only interactive destination")
    local card = actions[1]
    Assert.notNil(card, "the trainer card action must be present after its flag is set")
    Assert.equal(card.id, "vanilla.trainer_card", "the first interactive destination is the trainer card")
    Assert.equal(card.position, 0, "the trainer card is the first display position")
    Assert.equal(card.slotId, 2, "display position 0 occupies manifest slot 2")
    Assert.equal(card.targetApplication, "trainer_card", "the action must target the production card application")
    Assert.equal(hostStatus(game).menu.cursorSlotId, 2, "the unlocked menu selects the trainer card")
    local firstFrame = hostStatus(game).menu.cursorFrameIndex
    Assert.isTrue(type(firstFrame) == "number", "a selected menu must present the cursor animation frame")
    game:advanceUntil("the cursor animation advances", function()
      return hostStatus(game).menu.cursorFrameIndex ~= firstFrame
    end, 64)
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the empty-menu contract must not render")
  game:close()
end

function T.tests.empty_start_menu_pointer_slots_are_inert_and_the_cancel_region_still_closes()
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      viewportWidth = 256,
      viewportHeight = 192,
      screenTopology = canonicalTopology(),
    },
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    runtime:resizePresentation(256, 192, canonicalTopology())
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local menu = hostStatus(game).menu ---@type any
    Assert.isTrue(type(menu) == "table" and menu.open == true, "the empty menu must open on the canonical host")
    Assert.equal(#menu.actions, 0, "the canonical host must compose zero actions for a fresh game")

    -- An action slot with no action is inert: the tap must neither select
    -- nor activate anything and the menu stays open.
    local slots = runtime.uiManifest.startMenu.slots
    local slotTwo = assert(slots[2], "the manifest must expose the first action slot")
    tapSlot(game, slotTwo.x + slotTwo.width / 2, slotTwo.y + slotTwo.height / 2)
    Assert.equal(hostPhase(game), "menu", "an action-slot tap must not activate a slot with no action")
    Assert.equal(hostStatus(game).menu.open, true, "an action-slot tap must leave the empty menu open")
    Assert.isNil(hostStatus(game).applicationId, "an action-slot tap must not launch from an empty menu")

    -- The cancel region stays live: the tap closes the empty menu normally.
    local cancelSlot = assert(slots[1], "the manifest must expose the cancel region")
    tapSlot(game, cancelSlot.x + cancelSlot.width / 2, cancelSlot.y + cancelSlot.height / 2)
    advanceToPhase(game, "closed", 16)
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the empty-menu pointer contract must not render")
  game:close()
end

return T
