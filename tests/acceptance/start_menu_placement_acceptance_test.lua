-- Production-composed Start Menu placement contract: one placement record
-- owned by the runtime (runtime.startMenuPlacement) is shared by the
-- renderer channel and the pointer mapper. On a 1920x1080 expanded host the
-- menu must fit into the real right gutter defined by FieldViewport's
-- referenceFrame and never intersect that canonical frame; the placement
-- must exist before any resize so first-frame pointer input works; a
-- same-size topology change (safe rect only) must recompute the placement;
-- and a pointer press captured before such a change must not activate a
-- different post-change slot.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScriptSymbols = require("libs.assets.src.FieldScriptSymbols")
local ScreenTopology = require("libs.engine.src.ScreenTopology")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "start-menu", "application", "responsive", "topology", "hgss" },
  },
  tests = {},
}

-- The 1920x1080 expanded-host geometry: FieldViewport's reference frame
-- spans x 240..1680 (the 4:3-of-height world frame), so the real right
-- gutter the layout must fit into is x 1680..1920.
local function wideTopology(safeRect)
  return ScreenTopology.oneDisplay({
    id = "main",
    rect = { x = 0, y = 0, width = 1920, height = 1080 },
    safeRect = safeRect,
    touch = false,
    role = "world",
  })
end

local function hostStatus(game)
  local host = game.runtime.applicationHost
  ---@diagnostic disable-next-line: undefined-field -- the runtime application-host surface is the contract under test
  return host:status()
end

local function hostPhase(game)
  return hostStatus(game).phase
end

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

-- The forward transform of the placement record under test: the renderer
-- draws at frame origin + canonical * scale, so a canonical slot center maps
-- to exactly the host point the mapper must agree with.
local function slotCenter(placement, slot)
  ---@cast placement { frame: { x: number, y: number }, scale: number }
  assert(placement.frame ~= nil)
  assert(placement.scale ~= nil)
  local frame = placement.frame
  local scale = placement.scale
  local x, y = assert(slot.x ~= nil and slot.x), assert(slot.y ~= nil and slot.y)
  local width, height = assert(slot.width ~= nil and slot.width), assert(slot.height ~= nil and slot.height)
  return frame.x + (x + width / 2) * scale, frame.y + (y + height / 2) * scale
end

local function tapAt(game, x, y)
  game.runtime.input:pointerDown("mouse:1", x, y)
  game:step()
  game.runtime.input:pointerUp("mouse:1", x, y)
  game:step()
end

local function rectanglesDoNotIntersect(a, b)
  return a.x >= b.x + b.width or b.x >= a.x + a.width or a.y >= b.y + b.height or b.y >= a.y + a.height
end

function T.tests.wide_layout_places_the_start_menu_clear_of_the_reference_frame_with_one_shared_placement()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      viewportWidth = 1920,
      viewportHeight = 1080,
      screenTopology = wideTopology(nil),
    },
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime

    -- The initial placement exists as soon as the geometry is known: pointer
    -- input must work before any resize.
    ---@diagnostic disable-next-line: undefined-field -- the runtime placement surface is the contract under test
    local placement = runtime.startMenuPlacement
    Assert.isTrue(
      type(placement) == "table" and type(placement.frame) == "table" and type(placement.scale) == "number",
      "the runtime must own the initial start menu placement"
    )
    ---@diagnostic disable-next-line: need-check-nil -- asserted by the preceding isTrue contract
    local frame = placement.frame

    -- The 1920x1080 menu fits the real right gutter (x 1680..1920) and
    -- never overlaps the canonical 4:3 reference frame.
    local reference = runtime.viewport.referenceFrame
    Assert.isTrue(
      rectanglesDoNotIntersect(frame, reference),
      "the wide-layout start menu must not intersect the canonical reference frame, frame="
        .. tostring(frame.x)
        .. ","
        .. tostring(frame.y)
        .. " "
        .. tostring(frame.width)
        .. "x"
        .. tostring(frame.height)
    )

    -- The pointer mapper shares the runtime placement: a cancel tap derived
    -- from this exact record closes the menu, and an action-slot tap derived
    -- from the same record launches the trainer card.
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local slots = runtime.uiManifest.startMenu.slots
    local cancel = assert(slots[1], "the manifest must expose the cancel region")
    local cancelX, cancelY = slotCenter(placement, cancel)
    tapAt(game, cancelX, cancelY)
    advanceToPhase(game, "closed", 16)

    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local actionSlot = assert(slots[2], "the manifest must expose the first action slot")
    local actionX, actionY = slotCenter(placement, actionSlot)
    tapAt(game, actionX, actionY)
    advanceToPhase(game, "fading_out", 8)
    Assert.equal(hostStatus(game).applicationId, "trainer_card", "the shared placement must map the action slot")
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the placement contract must not render")
  game:close()
end

function T.tests.same_size_safe_rect_change_updates_the_placement_and_cancels_a_held_pointer_capture()
  local game = AcceptanceHarness.new():boot({
    versionId = AcceptanceHarness.defaultVersion(),
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = {
      viewportWidth = 1920,
      viewportHeight = 1080,
      screenTopology = wideTopology(nil),
    },
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    ---@diagnostic disable-next-line: undefined-field -- the runtime placement surface is the contract under test
    local first = runtime.startMenuPlacement
    Assert.isTrue(
      type(first) == "table" and type(first.frame) == "table",
      "the runtime must own the initial start menu placement"
    )
    ---@diagnostic disable-next-line: need-check-nil -- asserted by the preceding isTrue contract
    local firstFrame = first.frame
    game:setWorldState({ flag = FieldScriptSymbols.flagsByName.FLAG_GOT_TRAINER_CARD })
    pressMenuEdge(game)
    advanceToPhase(game, "menu", 16)
    local slots = runtime.uiManifest.startMenu.slots
    local actionSlot = assert(slots[2], "the manifest must expose the first action slot")
    local capturedX, capturedY = slotCenter(first, actionSlot)

    -- A press is captured on the trainer card slot before the geometry
    -- changes; it must not activate a different post-change slot.
    runtime.input:pointerDown("mouse:1", capturedX, capturedY)
    game:step()

    -- Same dimensions, changed safe rect: the structural presentation
    -- signature changed, so the placement must be recomputed.
    local changed = wideTopology({ x = 0, y = 0, width = 1600, height = 1080 })
    runtime:resizePresentation(1920, 1080, changed)
    ---@diagnostic disable-next-line: undefined-field -- the runtime placement surface is the contract under test
    local second = runtime.startMenuPlacement
    Assert.isTrue(
      type(second) == "table" and type(second.frame) == "table",
      "the runtime must recompute the placement for a changed safe rect"
    )
    ---@diagnostic disable-next-line: need-check-nil -- asserted by the preceding isTrue contract
    local secondFrame = second.frame
    Assert.equal(secondFrame.x, 80, "the same-size safe-rect change must recenter the menu in the new safe area")
    Assert.equal(secondFrame.width, 1440, "the same-size safe-rect change must refit the menu in the new safe area")
    Assert.isTrue(
      secondFrame.x ~= firstFrame.x or secondFrame.width ~= firstFrame.width,
      "the placement must change when the safe rect changes at the same dimensions"
    )

    runtime.input:pointerUp("mouse:1", capturedX, capturedY)
    game:step()
    Assert.equal(hostPhase(game), "menu", "a capture cancelled by the layout change must not activate a slot")
    Assert.equal(hostStatus(game).menu.open, true, "the cancelled capture must leave the menu open")

    -- Hit testing follows the new placement: a fresh tap at the new slot
    -- center launches the trainer card.
    local newX, newY = slotCenter(second, actionSlot)
    tapAt(game, newX, newY)
    advanceToPhase(game, "fading_out", 8)
    Assert.equal(hostStatus(game).applicationId, "trainer_card", "the pointer mapper must follow the new placement")
  end, debug.traceback)
  if not ok then
    error(err, 0)
  end
  Assert.equal(game:renderAttempts(), 0, "the placement-change contract must not render")
  game:close()
end

return T
