-- Production-composed application-host ownership contract: the runtime
-- registers the production Trainer Card destination only -- no boot-config
-- descriptor can add destinations, so the vanilla save action can never
-- become interactive -- and the application host owns the one modal
-- transition. The session steps the host; runtime disposal in every
-- application phase releases the modal before the save attempt; the resize
-- contract recomputes the shared placement and cancels an active menu
-- pointer capture so a press held across a layout change cannot activate a
-- different post-resize slot.

local Assert = require("tests.support.Assert")
local FieldSave = require("libs.engine.src.FieldSave")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local ScreenTopology = require("libs.engine.src.ScreenTopology")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "start-menu", "application", "transition" },
  },
  tests = {},
}

local function harness()
  return AcceptanceHarness.new({ versions = { "heartgold" } })
end

-- Every start-menu unlock flag: a fresh boot leaves them all unset, so the
-- zero-action composition is the precondition of the no-op scenario.
local UNLOCK_FLAGS = {
  FieldScriptSymbols.flagsByName.FLAG_GOT_POKEDEX,
  FieldScriptSymbols.flagsByName.FLAG_GOT_STARTER,
  FieldScriptSymbols.flagsByName.FLAG_GOT_BAG,
  FieldScriptSymbols.flagsByName.FLAG_GOT_POKEGEAR,
  FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD,
  FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON,
  FieldScriptSymbols.flagsByName.FLAG_GOT_OPTIONS_BUTTON,
}

-- The production composition: a fresh field boot with no descriptor options;
-- the real unlock flag makes the production Trainer Card interactive.
local function bootGame()
  local game = harness():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
  })
  game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
  return game
end

local function pressMenuEdge(game)
  game.runtime:pressMenu()
  game:step()
  game.runtime:releaseMenu()
end

local function advanceToPhase(game, phase, maxTicks)
  return game:advanceUntil("host reaches " .. phase, function()
    return game.runtime.applicationHost:status().phase == phase
  end, maxTicks)
end

local function openMenu(game)
  pressMenuEdge(game)
  advanceToPhase(game, "menu", 16)
end

local function confirmAction(game)
  game.runtime:pressAction()
  game:step()
  game.runtime:releaseAction()
end

-- The per-phase disposal matrix: runtime disposal in every application
-- phase releases the modal before the save attempt and closes cleanly. The
-- production Trainer Card destination carries the non-closed phases; the
-- exactly-once controller disposal is the host-unit contract, not this
-- composition's.
function T.tests.runtime_disposal_in_every_application_phase_releases_once()
  local cases = {
    {
      phase = "menu",
      walk = function(game)
        pressMenuEdge(game)
        advanceToPhase(game, "menu", 16)
      end,
    },
    {
      phase = "fading_out",
      walk = function(game)
        openMenu(game)
        confirmAction(game)
        advanceToPhase(game, "fading_out", 8)
      end,
    },
    {
      phase = "application",
      walk = function(game)
        openMenu(game)
        confirmAction(game)
        advanceToPhase(game, "application", 64)
      end,
    },
    {
      phase = "fading_in",
      walk = function(game)
        openMenu(game)
        confirmAction(game)
        advanceToPhase(game, "application", 64)
        game.runtime:pressCancel()
        game:step()
        game.runtime:releaseCancel()
        advanceToPhase(game, "fading_in", 64)
      end,
    },
  }
  for _, case in ipairs(cases) do
    local game = bootGame()
    local ok, err = xpcall(function()
      case.walk(game)
      Assert.equal(game.runtime.applicationHost:status().phase, case.phase, "the journey must reach " .. case.phase)
      game:close()
      Assert.equal(
        game.saveStatus:find("Field session saved", 1, true) ~= nil,
        true,
        case.phase .. " disposal must release the modal before the save attempt: " .. tostring(game.saveStatus)
      )
    end, debug.traceback)
    if not ok then
      error(err, 0)
    end
    game:close()
  end
end

-- The zero-action production composition: with no unlock flag set the
-- runtime's start-menu composition returns no interactive actions, so the
-- menu edge opens nothing -- the host stays closed with no menu surface, no
-- modal input lifetime, and no error -- and the field keeps simulating;
-- unlocking the trainer card makes the same edge open the real menu. The
-- nil-factory no-op itself is the FieldApplicationHost/FieldSession unit
-- contract; this test proves the production flag -> policy -> nil menu
-- composition path.
function T.tests.zero_interactive_actions_make_the_menu_edge_a_noop_and_the_field_continues()
  local game = harness():boot({
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
    local status = runtime.applicationHost:status()
    Assert.equal(status.menu, nil, "a zero-action menu press must not present a menu surface")
    Assert.equal(runtime.errorText, nil, "a zero-action menu press must not fail the runtime")
    Assert.equal(runtime.input.uiActive, false, "a zero-action menu press must not acquire the modal input lifetime")
    Assert.equal(
      FieldSave.canCapture(runtime.session),
      true,
      "a zero-action menu press must leave the field capturable"
    )

    -- The field continues normally: the world keeps simulating and the
    -- player can still move.
    local before = game:snapshot()
    game:move("west")
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
    local actions = runtime.applicationHost:status().menu.actions
    Assert.equal(#actions, 1, "the unlocked trainer card must be the only interactive destination")
    Assert.equal(actions[1].id, "vanilla.trainer_card", "the unlocked destination must be the trainer card")
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    Assert.equal(FieldSave.canCapture(runtime.session), true, "closing the menu must restore the capturable boundary")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The production destination catalogue is closed: the runtime registers the
-- Trainer Card itself, no boot option can add a destination, and the vanilla
-- save unlock flag can never make the save action interactive.
function T.tests.the_runtime_registers_production_destinations_only()
  local game = bootGame()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    Assert.equal(
      runtime.applications:has("trainer_card"),
      true,
      "the production runtime must register the trainer card itself"
    )
    Assert.equal(runtime.applications:has("save"), false, "no boot descriptor may register the save destination")
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local actions = game.runtime.applicationHost:status().menu.actions
    Assert.equal(#actions, 1, "the save unlock flag must not add an unregistered destination")
    Assert.equal(actions[1].id, "vanilla.trainer_card", "the trainer card stays the only interactive action")
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    Assert.equal(
      FieldSave.canCapture(runtime.session),
      true,
      "closing the menu must restore the capturable field boundary"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- A resize recomputes the shared placement and cancels an active menu
-- pointer capture, so a press held across the layout change cannot activate
-- a different post-resize slot. The production runtime exposes the resize
-- path; the capture cancellation is observed through the activation result
-- (without it, the same-slot release would launch the destination).
function T.tests.resize_cancels_an_active_menu_pointer_capture()
  local game = bootGame()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    local function topology(width, height)
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = width, height = height },
        role = "world",
        touch = true,
      })
    end
    -- Canonical (192, 19) is the center of manifest slot 2 (the fresh menu's
    -- first action, the production trainer card). The 4:3 surface scales
    -- uniformly, so that canonical point is (192, 19) at scale 1 and
    -- (768, 76) at scale 4.
    runtime:resizePresentation(256, 192, topology(256, 192))
    openMenu(game)
    runtime.input:pointerDown("touch:1", 192, 19)
    game:step()
    -- The capture is held across the resize; the release lands on the same
    -- canonical slot at the new scale and must be discarded by the
    -- cancellation (a press before a resize cannot activate post-resize).
    runtime:resizePresentation(1024, 768, topology(1024, 768))
    runtime.input:pointerUp("touch:1", 768, 76)
    game:step()
    Assert.equal(game.runtime.applicationHost:status().phase, "menu", "the menu must stay open")
    -- A fresh press after the resize lands on the same slot and activates.
    runtime.input:pointerDown("touch:1", 768, 76)
    runtime.input:pointerUp("touch:1", 768, 76)
    game:step()
    Assert.equal(
      game.runtime.applicationHost:status().phase,
      "fading_out",
      "the fresh press after the resize must activate the slot"
    )
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
