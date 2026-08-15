-- Production-composed application-host ownership contract: the runtime
-- composes the immutable destination registry (child applications only; the
-- start menu is the host's own factory) and the application host, the
-- session steps the host as the one application modal owner, and runtime
-- disposal in every application phase releases the active controller exactly
-- once, the modal input lifetime once, and defers the save. The boot-config
-- descriptor seam registers the destination factory under a canonical
-- vanilla destination id, unlocked through its real flag; the resize
-- contract recomputes the shared placement and cancels an active menu
-- pointer capture so a press held across a layout change cannot activate a
-- different post-resize slot; and the rebuild restores the remembered
-- selection by action id even when it is not the first enabled action.

local Assert = require("tests.support.Assert")
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

-- The fake destination rides the canonical save action: the boot-config
-- descriptor seam supplies a real registered "save" destination, and the
-- FLAG_GOT_SAVE_BUTTON unlock makes the vanilla save action interactive.
local DESTINATION_ID = "save"
local FACTORY_FAILURE_TEXT = "component injected destination factory failure"

local function fakeDestination(registry, id)
  local controller = {
    updateFixedCalls = 0,
    disposeCount = 0,
    result = nil,
    closed = false,
  }
  function controller:updateFixed(uiInput)
    self.updateFixedCalls = self.updateFixedCalls + 1
    if self.closed then
      return
    end
    for _, event in ipairs(uiInput) do
      if event.type == "cancel" then
        self.result = { kind = "close" }
        self.closed = true
      end
    end
  end
  function controller:status()
    return { open = not self.closed }
  end
  function controller:takeResult()
    local result = self.result
    self.result = nil
    if result ~= nil then
      self.closed = true
    end
    return result
  end
  function controller:dispose()
    self.disposeCount = self.disposeCount + 1
    self.result = nil
    self.closed = true
  end
  registry[id] = controller
  return controller
end

local function harness()
  return AcceptanceHarness.new({ versions = { "heartgold" } })
end

local function bootWithRegistry(options)
  options = options or {}
  local registry = {}
  local fieldOptions = {
    applicationDescriptors = {
      {
        id = DESTINATION_ID,
        factory = function()
          return fakeDestination(registry, DESTINATION_ID)
        end,
      },
    },
  }
  if options.applicationDescriptors then
    fieldOptions.applicationDescriptors = options.applicationDescriptors
  end
  if options.screenTopology then
    fieldOptions.screenTopology = options.screenTopology
  end
  local game = harness():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = fieldOptions,
  })
  -- The fake destination becomes interactive through its real unlock flag.
  game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
  return game, registry
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
-- phase releases the active controller exactly once, releases the modal
-- input lifetime, restores the capturable boundary before the save attempt,
-- and closes cleanly.
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
    local game, registry = bootWithRegistry()
    local ok, err = xpcall(function()
      case.walk(game)
      Assert.equal(game.runtime.applicationHost:status().phase, case.phase, "the journey must reach " .. case.phase)
      game:close()
      Assert.equal(
        game.saveStatus:find("Field session saved", 1, true) ~= nil,
        true,
        case.phase .. " disposal must release the modal before the save attempt: " .. tostring(game.saveStatus)
      )
      local destination = registry[DESTINATION_ID]
      if case.phase == "application" then
        Assert.equal(destination.disposeCount, 1, "disposal releases the active destination exactly once")
      elseif case.phase == "fading_in" then
        Assert.equal(destination.disposeCount, 1, "the returned destination stays released exactly once")
      end
    end, debug.traceback)
    if not ok then
      error(err, 0)
    end
    game:close()
  end
end

-- The terminal factory-failure phase: disposal after the retained failure
-- releases nothing twice and closes cleanly.
function T.tests.runtime_disposal_in_the_failed_phase_releases_cleanly()
  local game = harness():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      applicationDescriptors = {
        {
          id = DESTINATION_ID,
          factory = function()
            error(FACTORY_FAILURE_TEXT, 0)
          end,
        },
      },
    },
  })
  local ok, err = xpcall(function()
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
    openMenu(game)
    confirmAction(game)
    game:advanceUntil("the factory failure is retained", function()
      return game.runtime.errorText ~= nil
    end, 96)
    Assert.isTrue(
      game.runtime.errorText:find(FACTORY_FAILURE_TEXT, 1, true) ~= nil,
      "the retained error must carry the original factory failure"
    )
    game:close()
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  game:close()
end

-- A resize recomputes the shared placement and cancels an active menu
-- pointer capture, so a press held across the layout change cannot activate
-- a different post-resize slot. The production runtime exposes the resize
-- path; the capture cancellation is observed through the activation result
-- (without it, the same-slot release would launch the destination).
function T.tests.resize_cancels_an_active_menu_pointer_capture()
  local game, _ = bootWithRegistry()
  local ok, err = xpcall(function()
    local runtime = game.runtime
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
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

-- The rebuilt menu restores the selection by action id: navigating to a
-- non-first enabled action, launching it, and returning must restore that
-- action's slot, not the first-enabled fallback. The save destination rides
-- slot 3 below the production trainer card (slot 2).
function T.tests.the_rebuild_restores_the_remembered_selection_by_action_id()
  local registry = {}
  local game = harness():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      applicationDescriptors = {
        {
          id = DESTINATION_ID,
          factory = function()
            return fakeDestination(registry, DESTINATION_ID)
          end,
        },
      },
    },
  })
  local ok, err = xpcall(function()
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_SAVE_BUTTON })
    openMenu(game)
    local actions = game.runtime.applicationHost:status().menu.actions
    Assert.equal(#actions, 2, "both enabled actions must be visible")
    Assert.equal(actions[2].id, "vanilla.save")
    -- Navigate down to the save action and launch it.
    game.runtime.input:pressDirection("south", "test:navigate")
    game:step()
    game.runtime.input:releaseDirection("test:navigate")
    Assert.equal(game.runtime.applicationHost:status().menu.cursorSlotId, 3)
    confirmAction(game)
    advanceToPhase(game, "application", 64)
    Assert.equal(game.runtime.applicationHost:status().applicationId, DESTINATION_ID)
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    advanceToPhase(game, "menu", 64)
    Assert.equal(
      game.runtime.applicationHost:status().menu.cursorSlotId,
      3,
      "the rebuild must restore the remembered action, not the first-enabled fallback"
    )
    Assert.equal(registry[DESTINATION_ID].disposeCount, 1, "the returned destination is disposed exactly once")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
