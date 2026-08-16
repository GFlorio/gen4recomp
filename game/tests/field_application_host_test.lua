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
