-- Production-composed Main Menu acceptance contract. The menu state owns the
-- C01 boundary and semantic input/layout state; this suite stops before draw
-- and uses only an injected save catalog and ready-version resolver.

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")
local Errors = require("libs.errors.src.Errors")
local FieldState = require("game.src.game.FieldState")
local RomImporter = require("romdump.src.source.RomImporter")

local T = {
  metadata = {
    tags = { "main-menu", "product", "routing" },
  },
  tests = {},
}

local MAIN_MENU_MODULE = "game.src.game.MainMenuState"
local READY_VERSION = "heartgold"

local function requireMainMenuState()
  local ok, moduleOrError = pcall(require, MAIN_MENU_MODULE)
  Assert.isTrue(
    ok,
    "ready product boot must provide a Main Menu state; the current product still has no menu boundary: "
      .. tostring(moduleOrError)
  )
  Assert.isTrue(type(moduleOrError.new) == "function", "the Main Menu state must expose its production constructor")
  return moduleOrError
end

local function saveRecord(saveId, name, seconds, versionId)
  return {
    saveId = saveId,
    versionId = versionId or READY_VERSION,
    playerData = { profile = { name = name } },
    playTimeSeconds = seconds,
  }
end

local function fakeStore(entries, listError)
  local store = {
    entries = entries,
    listError = listError,
    calls = { list = 0, load = {}, delete = {} },
  }

  function store:list()
    self.calls.list = self.calls.list + 1
    if self.listError then
      error(self.listError)
    end
    return self.entries
  end

  function store:load(saveId)
    self.calls.load[#self.calls.load + 1] = saveId
    for _, entry in ipairs(self.entries) do
      if entry.saveId == saveId then
        if entry.error then
          error(entry.error)
        end
        return entry
      end
    end
    error("missing fake save " .. saveId)
  end

  function store:delete(saveId)
    self.calls.delete[#self.calls.delete + 1] = saveId
    for index, entry in ipairs(self.entries) do
      if entry.saveId == saveId then
        table.remove(self.entries, index)
        return true
      end
    end
    error("missing fake save " .. saveId)
  end

  return store
end

local function newMenu(store, onResult, width, height, readyVersions)
  local MainMenuState = requireMainMenuState()
  local ok, menuOrError = pcall(MainMenuState.new, {
    saveStore = store,
    readyVersions = readyVersions or { READY_VERSION },
    onResult = onResult,
    width = width or 960,
    height = height or 540,
  })
  Assert.isTrue(
    ok,
    "Main Menu construction must fail only for invalid production state, got: " .. tostring(menuOrError)
  )
  return menuOrError
end

local function view(menu)
  Assert.isTrue(type(menu.view) == "function", "Main Menu must expose a semantic view model")
  return assert(menu:view())
end

local function itemById(menu, itemId)
  for _, item in ipairs(view(menu).items) do
    if item.id == itemId then
      return item
    end
  end
  error("menu item is not visible: " .. itemId, 2)
end

local function rectCenter(rect)
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

local function activateKey(menu, key)
  menu:keypressed(key, key, false)
end

local function confirmDelete(menu)
  local current = view(menu)
  local deleteRect = assert(current.layout.dialog.delete)
  local x, y = rectCenter(deleteRect)
  menu:mousepressed(x, y, 1, false, 1)
end

local function assertValidCard(card, saveId, playerName, playTimeLabel)
  Assert.keySet(card, "canContinue,canDelete,id,playTimeLabel,playerName,saveId")
  Assert.equal(card.saveId, saveId)
  Assert.equal(card.playerName, playerName)
  Assert.equal(card.playTimeLabel, playTimeLabel)
  Assert.isTrue(card.canContinue)
  Assert.isTrue(card.canDelete)
end

local function withAppBoot(fn)
  local originalOpts = App.opts
  local originalState = App.state
  local originalImporter = App.importer
  local originalIsReady = RomImporter.isReady
  local originalFieldNew = FieldState.new
  local fieldCalls = {}

  ---@type AppOptions
  App.opts = {
    test = false,
    actors = false,
    dev = false,
    newGameCandidateFactory = function()
      return {}
    end,
    oakIntroOptionsFactory = function()
      return {}
    end,
    saveStore = fakeStore({}),
  }
  App.state = nil
  App.importer = nil
  ---@diagnostic disable-next-line: duplicate-set-field
  RomImporter.isReady = function(versionId)
    return versionId == READY_VERSION
  end
  FieldState.new = function(...)
    fieldCalls[#fieldCalls + 1] = { ... }
    return { kind = "field" }
  end

  local ok, err = xpcall(function()
    fn(fieldCalls)
  end, debug.traceback)

  App.setState(nil)
  App.opts = originalOpts
  App.state = originalState
  App.importer = originalImporter
  RomImporter.isReady = originalIsReady
  FieldState.new = originalFieldNew
  if not ok then
    error(err, 0)
  end
end

-- The New Game card enters the real Oak state boundary. The semantic Oak
-- resources are injected at the cache/audio host seam; MainMenuState, App,
-- and OakIntroState remain the production composition under test.
function T.tests.new_game_enters_oak_and_completion_hands_off_without_publishing()
  local originalOpts = App.opts
  local originalState = App.state
  local originalImporter = App.importer
  local originalFieldNew = FieldState.new
  local candidate = { saveId = "save-00000007", playerData = { profile = { name = "GOLD" } } }
  local handoffs = {}
  local fieldCalls = {}
  local publishCalls = 0
  local controller = { phase = "opening_wait", started = 0, disposed = 0 }
  function controller:start()
    self.started = self.started + 1
  end
  function controller:tick() end
  function controller:press() end
  function controller:inputText() end
  function controller:deleteGlyph() end
  function controller:dispose()
    self.disposed = self.disposed + 1
  end
  function controller:view()
    return {
      phase = self.phase,
      name = "",
      message = "generated",
      visual = "background",
      genderFocus = 0,
      nameInputEnabled = false,
    }
  end
  function controller:result()
    return candidate
  end

  local renderer = { disposed = 0 }
  function renderer:draw() end
  function renderer:dispose()
    self.disposed = self.disposed + 1
  end
  local inputHost = { calls = {} }
  function inputHost:setTextInput(enabled)
    self.calls[#self.calls + 1] = enabled
  end

  local store = fakeStore({})
  function store:publishFirst()
    publishCalls = publishCalls + 1
  end
  ---@type AppOptions
  App.opts = {
    test = false,
    actors = false,
    dev = false,
    saveStore = store,
    oakIntroOptionsFactory = function(options)
      Assert.equal(options.candidate, candidate)
      Assert.equal(options.versionId, READY_VERSION)
      return {
        controller = controller,
        manifest = {},
        renderer = renderer,
        textInputHost = inputHost,
        glyphs = { "A" },
        width = 960,
        height = 540,
      }
    end,
    newGameCandidateFactory = function(options)
      Assert.equal(options.versionId, READY_VERSION)
      return candidate
    end,
  }
  ---@diagnostic disable-next-line: duplicate-set-field
  FieldState.new = function(game, options)
    fieldCalls[#fieldCalls + 1] = { game = game, options = options }
    return { kind = "field" }
  end
  App.state = nil
  App.importer = nil

  local ok, err = xpcall(function()
    App._bootMainMenu({ READY_VERSION })
    App.keypressed("return")
    Assert.equal(controller.started, 1)
    Assert.equal(getmetatable(App.state).__index, require("game.src.game.OakIntroState"))
    Assert.deepEqual(handoffs, {})

    controller.phase = "complete"
    App.update(0)
    Assert.deepEqual(handoffs, {})
    Assert.equal(#fieldCalls, 1)
    Assert.equal(fieldCalls[1].game, candidate)
    Assert.equal(App.state.kind, "field")
    Assert.equal(publishCalls, 0)
    Assert.equal(controller.disposed, 1)
    Assert.equal(renderer.disposed, 1)
  end, debug.traceback)

  App.setState(nil)
  App.opts = originalOpts
  App.state = originalState
  App.importer = originalImporter
  FieldState.new = originalFieldNew
  if not ok then
    error(err, 0)
  end
end

-- The normal ready and completed-import routes must stop at the menu. The
-- FieldState seam is only an observer: constructing it is the forbidden
-- behavior being caught, not a replacement runtime used by the scenario.
function T.tests.ready_and_imported_product_boot_stops_at_the_main_menu()
  withAppBoot(function(fieldCalls)
    App._bootExisting()
    Assert.equal(#fieldCalls, 0, "ready product boot must not construct FieldState before a menu decision")
    Assert.equal(view(App.state).kind, "main_menu")

    App._onImported(READY_VERSION)
    Assert.equal(#fieldCalls, 0, "completed import must enter Main Menu before constructing FieldState")
    Assert.equal(view(App.state).kind, "main_menu")
  end)
end

-- The menu exposes only the New Game sentinel and catalog-visible records,
-- preserving creation order and deriving sparse card metadata on refresh.
function T.tests.published_cards_are_sparse_and_creation_ordered()
  local store = fakeStore({
    saveRecord("save-00000001", "ADA", 0),
    saveRecord("save-00000003", "BEA", 3599),
    saveRecord("save-00000004", "CYR", 3599999),
  })
  local results = {}
  local menu = newMenu(store, function(result)
    results[#results + 1] = result
  end)

  local initial = view(menu)
  Assert.equal(initial.kind, "main_menu")
  Assert.deepEqual(
    { initial.items[1].id, initial.items[2].id, initial.items[3].id, initial.items[4].id },
    { "new-game", "save-00000001", "save-00000003", "save-00000004" }
  )
  assertValidCard(initial.items[2], "save-00000001", "ADA", "0:00")
  assertValidCard(initial.items[3], "save-00000003", "BEA", "0:59")
  assertValidCard(initial.items[4], "save-00000004", "CYR", "999:59")
  for _, card in ipairs({ initial.items[2], initial.items[3], initial.items[4] }) do
    for _, forbidden in ipairs({ "map", "mapName", "versionId", "timestamp", "saveIdPath", "mod", "money" }) do
      Assert.isNil(card[forbidden], "save card must not expose " .. forbidden)
    end
  end

  menu:refresh()
  local refreshed = view(menu)
  Assert.deepEqual(
    { refreshed.items[2].id, refreshed.items[3].id, refreshed.items[4].id },
    { "save-00000001", "save-00000003", "save-00000004" },
    "refresh must preserve C01 creation order"
  )

  activateKey(menu, "down")
  activateKey(menu, "down")
  activateKey(menu, "return")
  Assert.deepEqual(results[1], { kind = "continue", game = store.entries[2] })
end

-- Keyboard, gamepad, pointer, touch, resize, and scrolling all operate on
-- semantic focus. Pointer activation reads the same body rectangle returned
-- in the layout view, so drawing and hit testing cannot drift apart.
function T.tests.cross_input_focus_activation_and_resize_keep_logical_focus()
  local entries = {}
  for index = 1, 8 do
    entries[#entries + 1] = saveRecord(string.format("save-%08d", index), "P" .. index, index * 60)
  end
  local results = {}
  local menu = newMenu(fakeStore(entries), function(result)
    results[#results + 1] = result
  end, 320, 180)

  for _ = 1, 40 do
    activateKey(menu, "down")
  end
  local focused = view(menu)
  Assert.equal(focused.focusedId, "save-00000008")
  Assert.isTrue(focused.scroll.offset > 0, "focus changes must scroll a long menu")
  activateKey(menu, "down")
  Assert.equal(view(menu).focusedId, "save-00000008", "Down must clamp at the last item")

  menu:resize(1200, 700)
  local resized = view(menu)
  Assert.equal(resized.focusedId, "save-00000008", "resize must preserve logical focus")
  Assert.equal(resized.dialog, nil, "resize must not create a dialog")
  Assert.equal(resized.layout.viewport.width, 1200)
  Assert.equal(resized.layout.viewport.height, 700)

  activateKey(menu, "up")
  Assert.equal(view(menu).focusedId, "save-00000007")
  menu:gamepadpressed(nil, "a")
  Assert.deepEqual(results[1], { kind = "continue", game = entries[7] })

  local body = assert(view(menu).layout.cards["save-00000007"].body)
  local x, y = rectCenter(body)
  menu:mousepressed(x, y, 1, false, 1)
  Assert.deepEqual(results[2], { kind = "continue", game = entries[7] })

  menu:touchpressed("finger-1", x, y, 0, 0, 1)
  Assert.deepEqual(results[3], { kind = "continue", game = entries[7] })
end

-- Delete is a separate, confirmed action. The one scenario covers all
-- boundary positions and asserts the deterministic replacement focus.
function T.tests.delete_requires_confirmation_and_focuses_the_replacement_item()
  local cases = {
    { target = "save-00000001", expected = "save-00000002" },
    { target = "save-00000002", expected = "save-00000003" },
    { target = "save-00000003", expected = "save-00000002" },
    { target = "save-00000001", expected = "new-game", only = true },
  }

  for _, case in ipairs(cases) do
    local entries
    if case.only then
      entries = { saveRecord(case.target, "ONLY", 1) }
    else
      entries = {
        saveRecord("save-00000001", "ONE", 1),
        saveRecord("save-00000002", "TWO", 2),
        saveRecord("save-00000003", "THREE", 3),
      }
    end
    local store = fakeStore(entries)
    local menu = newMenu(store, function() end)
    while view(menu).focusedId ~= case.target do
      activateKey(menu, "down")
    end

    activateKey(menu, "delete")
    local requested = view(menu)
    Assert.equal(requested.dialog.kind, "delete")
    Assert.equal(requested.dialog.saveId, case.target)
    Assert.equal(requested.dialog.focusedAction, "cancel", "delete confirmation must default to Cancel")
    Assert.deepEqual(store.calls.delete, {}, "requesting deletion must not mutate C01")

    activateKey(menu, "escape")
    Assert.deepEqual(store.calls.delete, {}, "Escape must cancel deletion")

    activateKey(menu, "delete")
    menu:gamepadpressed(nil, "x")
    Assert.deepEqual(store.calls.delete, {}, "gamepad X must request confirmation, not delete")
    confirmDelete(menu)
    Assert.deepEqual(store.calls.delete, { case.target })
    Assert.equal(view(menu).focusedId, case.expected)
  end
end

-- Corrupt and content-unavailable records remain visible and deletable while
-- Continue is disabled; an independent catalog failure is also represented
-- as a recoverable menu error rather than an empty catalog.
function T.tests.broken_and_unavailable_cards_remain_recoverable()
  local corrupt = Errors.new("GAME_SAVE_SCHEMA_UNSUPPORTED", "corrupt save")
  local store = fakeStore({
    saveRecord("save-00000001", "GOOD", 60),
    { saveId = "save-00000002", error = corrupt },
    saveRecord("save-00000003", "UNAVAILABLE", 120, "soulsilver"),
  })
  local results = {}
  local menu = newMenu(store, function(result)
    results[#results + 1] = result
  end, 960, 540, { READY_VERSION })
  local current = view(menu)

  Assert.isTrue(current.items[2].canContinue)
  Assert.isFalse(current.items[3].canContinue)
  Assert.isTrue(current.items[3].canDelete)
  Assert.isFalse(current.items[4].canContinue)
  Assert.isTrue(current.items[4].canDelete)
  Assert.equal(current.items[3].errorSummary, "corrupt save")
  Assert.isTrue(current.items[4].errorSummary ~= nil)

  activateKey(menu, "down")
  activateKey(menu, "down")
  activateKey(menu, "return")
  Assert.equal(#results, 0, "an error card must not emit Continue")
  activateKey(menu, "down")
  activateKey(menu, "return")
  Assert.equal(#results, 0, "a content-unavailable card must not emit Continue")

  activateKey(menu, "delete")
  confirmDelete(menu)
  Assert.deepEqual(store.calls.delete, { "save-00000003" })
  Assert.equal(view(menu).items[2].id, "save-00000001")
  Assert.isTrue(view(menu).items[2].canContinue, "the valid neighbor must remain usable after bad-save deletion")

  local catalogError = Errors.new("GAME_SAVE_CATALOG_INVALID", "catalog unreadable")
  local failedMenu = newMenu(fakeStore({}, catalogError), function() end)
  local failedView = view(failedMenu)
  Assert.notNil(failedView.catalogError, "catalog failure must be visible as a recoverable menu error")
  Assert.isFalse(failedView.catalogError == "no saves", "catalog failure must not be treated as an empty catalog")
end

-- Root Escape is a deliberate quit result, root gamepad B is a no-op, and
-- dialog cancellation retains its separate semantics. Responsive layout and
-- mutually exclusive body/delete hit regions are checked in the same flow.
function T.tests.responsive_root_and_delete_hit_semantics_are_deliberate()
  local results = {}
  local menu = newMenu(fakeStore({ saveRecord("save-00000001", "PLAYER", 60) }), function(result)
    results[#results + 1] = result
  end, 240, 160)

  local narrow = view(menu)
  local card = assert(narrow.layout.cards["save-00000001"])
  local bodyX, bodyY = rectCenter(card.body)
  local deleteX, deleteY = rectCenter(card.delete)
  Assert.notNil(menu:hitTest(bodyX, bodyY).primary)
  Assert.equal(menu:hitTest(deleteX, deleteY).delete, "save-00000001")
  Assert.isNil(menu:hitTest(deleteX, deleteY).primary, "delete and card body hit regions must be exclusive")
  Assert.isTrue(card.body.width >= 1 and card.body.height >= 1)
  Assert.isTrue(card.delete.width >= 1 and card.delete.height >= 1)

  menu:resize(1400, 900)
  local wide = view(menu)
  Assert.equal(wide.layout.viewport.width, 1400)
  Assert.equal(wide.layout.viewport.height, 900)
  Assert.equal(wide.focusedId, "new-game")

  App.state = menu
  App.keypressed("escape")
  Assert.deepEqual(results[1], { kind = "quit" })
  App.gamepadpressed(nil, "b")
  Assert.equal(#results, 1, "root gamepad B must not quit")

  activateKey(menu, "down")
  activateKey(menu, "delete")
  App.keypressed("escape")
  Assert.equal(view(menu).dialog, nil, "Escape must cancel the delete dialog")
  App.gamepadpressed(nil, "b")
  Assert.equal(view(menu).dialog, nil, "dialog gamepad B must remain a cancel without deleting")
  App.state = nil
end

return T
