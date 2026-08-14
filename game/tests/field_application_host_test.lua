-- Production-composed application-host ownership contract: the runtime
-- composes the sealed application registry and the application host, the
-- session steps the host as the one application modal owner, and runtime
-- disposal in every application phase releases the active controller exactly
-- once, the modal input lifetime once, and defers the save. The boot-config
-- descriptor seam registers the destination factories; the audio facade
-- routes the semantic Start Menu requests through the script audio seam;
-- the resize contract cancels an active menu pointer capture so a press
-- held across a layout change cannot activate a different post-resize slot;
-- and the rebuild restores the remembered selection by action id even when
-- it is not the first enabled action.

local Assert = require("tests.support.Assert")
local ScreenTopology = require("libs.engine.src.ScreenTopology")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "start-menu", "application", "transition" },
  },
  tests = {},
}

local DESTINATION_ID = "trainer_card"
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
  if options.development then
    fieldOptions.development = true
  end
  if options.applicationDescriptors then
    fieldOptions.applicationDescriptors = options.applicationDescriptors
  end
  if options.startMenuDescriptors then
    fieldOptions.startMenuDescriptors = options.startMenuDescriptors
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

local function launchDestination(game, maxTicks)
  confirmAction(game)
  advanceToPhase(game, "application", 64)
end

local function audioEntries(game)
  local entries = {}
  for _, entry in ipairs(game.hosts.effects) do
    if type(entry) == "string" and entry:sub(1, 6) == "audio:" then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

-- The per-phase disposal matrix: runtime disposal in every application
-- phase releases the active controller exactly once, releases the modal
-- input lifetime, defers the save, and closes cleanly.
function T.tests.runtime_disposal_in_every_application_phase_releases_once()
  local cases = {
    {
      phase = "opening_menu",
      walk = function(game)
        pressMenuEdge(game)
      end,
    },
    {
      phase = "menu",
      walk = function(game)
        openMenu(game)
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
        launchDestination(game)
      end,
    },
    {
      phase = "fading_in",
      walk = function(game)
        openMenu(game)
        launchDestination(game)
        game.runtime:pressCancel()
        game:step()
        game.runtime:releaseCancel()
        advanceToPhase(game, "fading_in", 64)
      end,
    },
    {
      phase = "closing_menu",
      walk = function(game)
        openMenu(game)
        pressMenuEdge(game)
        advanceToPhase(game, "closing_menu", 16)
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
        game.saveStatus:find("Save deferred", 1, true) ~= nil,
        true,
        case.phase .. " disposal must defer the save"
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

-- The application-audio facade routes the semantic Start Menu requests
-- through the script audio seam: every production menu construction requests
-- exactly the open sound, and a close requests exactly the cancel sound.
function T.tests.the_audio_facade_routes_through_the_script_audio_seam()
  local game, _ = bootWithRegistry()
  local ok, err = xpcall(function()
    openMenu(game)
    Assert.deepEqual(audioEntries(game), { "audio:start_menu.open" })
    pressMenuEdge(game)
    advanceToPhase(game, "closed", 16)
    Assert.deepEqual(audioEntries(game), { "audio:start_menu.open", "audio:start_menu.cancel" })
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- §22.1/§41: a resize recomputes the placement and cancels an active menu
-- pointer capture, so a press held across the layout change cannot activate
-- a different post-resize slot. The production runtime exposes the resize
-- path; the capture cancellation is observed through the activation result
-- (without it, the same-slot release would play the select sound and launch).
function T.tests.resize_cancels_an_active_menu_pointer_capture()
  local game, _ = bootWithRegistry()
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
    -- only visible action). The 4:3 surface scales uniformly, so that
    -- canonical point is (192, 19) at scale 1 and (768, 76) at scale 4.
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
    Assert.deepEqual(audioEntries(game), { "audio:start_menu.open" }, "the cancelled press must not activate")
    Assert.equal(game.runtime.applicationHost:status().phase, "menu", "the menu must stay open")
    -- A fresh press after the resize lands on the same slot and activates.
    runtime.input:pointerDown("touch:1", 768, 76)
    runtime.input:pointerUp("touch:1", 768, 76)
    game:step()
    Assert.deepEqual(audioEntries(game), { "audio:start_menu.open", "audio:start_menu.select" })
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

-- The rebuilt menu restores the selection by action id: navigating to a
-- non-first enabled action, launching it, and returning must restore that
-- action's slot, not the first-enabled fallback.
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
        {
          id = "my_mod.quest_log",
          factory = function()
            return fakeDestination(registry, "my_mod.quest_log")
          end,
        },
      },
      startMenuDescriptors = {
        {
          id = "my_mod.quest_log",
          label = "msg.hgss.0542.00034",
          icon = "asset.my_mod.quest_log_icon",
          targetApplication = "my_mod.quest_log",
          placement = { after = "vanilla.trainer_card" },
        },
      },
    },
  })
  local ok, err = xpcall(function()
    openMenu(game)
    local actions = game.runtime.applicationHost:status().menu.actions
    Assert.equal(#actions, 2, "both enabled actions must be visible")
    Assert.equal(actions[2].id, "my_mod.quest_log")
    Assert.equal(actions[2].enabled, true)
    -- Navigate down to the mod action and launch it.
    game.runtime.input:pressDirection("south", "test:navigate")
    game:step()
    game.runtime.input:releaseDirection("test:navigate")
    Assert.equal(game.runtime.applicationHost:status().menu.cursorSlotId, 3)
    confirmAction(game)
    advanceToPhase(game, "application", 64)
    Assert.equal(game.runtime.applicationHost:status().applicationId, "my_mod.quest_log")
    game.runtime:pressCancel()
    game:step()
    game.runtime:releaseCancel()
    advanceToPhase(game, "menu", 64)
    Assert.equal(
      game.runtime.applicationHost:status().menu.cursorSlotId,
      3,
      "the rebuild must restore the remembered action, not the first-enabled fallback"
    )
    Assert.equal(registry["my_mod.quest_log"].disposeCount, 1, "the returned destination is disposed exactly once")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
