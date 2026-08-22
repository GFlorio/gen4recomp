-- Lower-layer contracts for the product Main Menu's pure formatting, focus,
-- layout, and catalog-error behavior.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local MainMenuController = require("game.src.game.MainMenuController")
local MainMenuLayout = require("game.src.game.MainMenuLayout")
local MainMenuState = require("game.src.game.MainMenuState")

local T = {}

local function item(id, canContinue)
  return {
    id = id,
    saveId = id == "new-game" and nil or id,
    playerName = id,
    playTimeLabel = "0:00",
    canContinue = canContinue,
    canDelete = id ~= "new-game",
  }
end

local function items(ids)
  local result = {}
  for _, id in ipairs(ids) do
    result[#result + 1] = item(id, true)
  end
  return result
end

function T.formats_capped_play_time_as_hours_and_minutes()
  Assert.equal(MainMenuState.formatPlayTime(0), "0:00")
  Assert.equal(MainMenuState.formatPlayTime(59 * 60 + 59), "0:59")
  Assert.equal(MainMenuState.formatPlayTime(60 * 60), "1:00")
  Assert.equal(MainMenuState.formatPlayTime(999 * 60 * 60 + 59 * 60 + 59), "999:59")
end

function T.delete_focus_uses_the_replacement_item_at_each_boundary()
  local cases = {
    { target = "one", expected = "two", ids = { "new-game", "one", "two" } },
    {
      target = "two",
      expected = "three",
      ids = { "new-game", "one", "two", "three" },
    },
    {
      target = "three",
      expected = "two",
      ids = { "new-game", "one", "two", "three" },
    },
  }
  for _, case in ipairs(cases) do
    local controller = MainMenuController.new(items(case.ids))
    controller:setFocusedId(case.target)
    Assert.isTrue(controller:requestDelete())
    controller:chooseDialogAction("delete")
    Assert.equal(controller:confirmDelete(), case.target)
    controller:setItems({ item("new-game", true), item("one", true), item("two", true), item("three", true) })
    local remaining = {}
    for _, candidate in ipairs(controller.items) do
      if candidate.id ~= case.target then
        remaining[#remaining + 1] = candidate
      end
    end
    controller:setItems(remaining)
    Assert.equal(controller:focusedId(), case.expected)
  end

  local only = MainMenuController.new(items({ "new-game", "only" }))
  only:setFocusedId("only")
  Assert.isTrue(only:requestDelete())
  only:chooseDialogAction("delete")
  Assert.equal(only:confirmDelete(), "only")
  only:setItems({ item("new-game", true) })
  Assert.equal(only:focusedId(), "new-game")
end

function T.layout_keeps_card_body_and_delete_hit_regions_exclusive()
  local items = { item("new-game", true), item("save-1", true) }
  local layout = MainMenuLayout.compute(items, 2, 240, 160, 0, nil)
  local card = layout.cards["save-1"]
  Assert.isTrue(card.body.width > 0 and card.delete.width > 0)
  Assert.isTrue(MainMenuLayout.contains(card.body, card.body.x + 1, card.body.y + 1))
  Assert.isTrue(MainMenuLayout.contains(card.delete, card.delete.x + 1, card.delete.y + 1))
  Assert.isFalse(MainMenuLayout.contains(card.body, card.delete.x + 1, card.delete.y + 1))
end

function T.refresh_preserves_focus_by_stable_save_identity()
  local controller = MainMenuController.new({ item("new-game", true), item("one", true), item("two", true) })
  controller:setFocusedId("two")
  controller:setItems({ item("new-game", true), item("one", true), item("two", true), item("three", true) })
  Assert.equal(controller:focusedId(), "two")
  controller:setItems({ item("new-game", true), item("one", true), item("three", true) })
  Assert.equal(controller:focusedId(), "three")
end

function T.catalog_error_is_not_represented_as_an_empty_catalog()
  local catalogError = Errors.new("GAME_SAVE_CATALOG_INVALID", "catalog unreadable")
  local store = {
    list = function()
      error(catalogError)
    end,
  }
  local menu = MainMenuState.new({ saveStore = store, readyVersions = { "heartgold" }, width = 640, height = 480 })
  local view = menu:view()
  Assert.notNil(view.catalogError)
  Assert.equal(#view.items, 1)
  Assert.equal(view.items[1].id, "new-game")
end

function T.malformed_save_metadata_is_an_unavailable_deletable_card()
  local menu = MainMenuState.new({
    saveStore = {
      list = function()
        return { { saveId = "save-00000001", playerData = {} } }
      end,
    },
    readyVersions = { "heartgold" },
    width = 640,
    height = 480,
  })
  local card = menu:view().items[2]
  Assert.equal(card.id, "save-00000001")
  Assert.isFalse(card.canContinue)
  Assert.isTrue(card.canDelete)
  Assert.notNil(card.errorSummary)
end

function T.continue_emits_the_loaded_canonical_record_without_another_read()
  local loaded = {
    saveId = "save-00000001",
    versionId = "heartgold",
    playerData = { profile = { name = "GOLD" } },
    playTimeSeconds = 0,
  }
  local loads = 0
  local results = {}
  local menu = MainMenuState.new({
    saveStore = {
      list = function()
        return { loaded }
      end,
      load = function(_, saveId)
        loads = loads + 1
        Assert.equal(saveId, loaded.saveId)
        return loaded
      end,
    },
    readyVersions = { "heartgold" },
    onResult = function(result)
      results[#results + 1] = result
    end,
    width = 640,
    height = 480,
  })
  menu:keypressed("down")
  menu:keypressed("return")
  Assert.equal(loads, 1)
  Assert.deepEqual(results, { { kind = "continue", game = loaded } })
end

return { tests = T }
