-- App state replacement tests. App.setState is the single transition point
-- between top-level states: it must dispose the previous state exactly once,
-- tolerate states without a disposal hook (the one centralized optional
-- check), and guarantee application quit can never dispose a state twice.
-- Import sessions are single-use: a file drop must always enter a fresh
-- import session through the import state and never invoke an importer left
-- over from a previous session.

---@diagnostic disable: duplicate-set-field -- seams below are stubbed per test and restored by the harness

local Assert = require("tests.support.Assert")
local App = require("game.src.game.App")
local ImportState = require("game.src.launcher.ImportState")
local ActorPreviewState = require("game.src.game.ActorPreviewState")
local RomImporter = require("romdump.src.source.RomImporter")
local FieldState = require("game.src.game.FieldState")
local VersionSelectState = require("game.src.launcher.VersionSelectState")

local T = {}

-- A contract state that counts disposal invocations.
local function countingState()
  local state = { disposed = 0 }
  function state:dispose()
    self.disposed = self.disposed + 1
  end
  return state
end

-- Clear module state so tests are independent of each other and of the boot
-- flow tests.
local function fresh()
  App.state = nil
  App.importer = nil
end

local function withInputState(fn)
  fresh()
  local calls = {}
  local state = {}
  for _, name in ipairs({
    "gamepadaxis",
    "mousepressed",
    "mousemoved",
    "mousereleased",
    "wheelmoved",
    "touchpressed",
    "touchmoved",
    "touchreleased",
  }) do
    state[name] = function(_, ...)
      calls[name] = { ... }
    end
  end
  App.setState(state)

  local ok, err = pcall(fn, calls)
  App.setState(nil)
  if not ok then
    error(err, 0)
  end
end

-- One harness for every App-level seam a test can touch: fresh module state,
-- the App opts the boot/draw paths read, the RomImporter.isReady seam, a
-- FieldState.new capture (so boot tests never construct a real runtime), and
-- a graphics.print spy. Every stub is restored on every path, so no test
-- leaks options or stubs into the next.
---@class AppStateHarness
---@field prints integer
---@field captured table|nil
---@field state table
---@param opts table|nil
---@param ready fun(id: string): boolean
---@param fn fun(result: AppStateHarness)
---@return AppStateHarness
local function withAppHarness(opts, ready, fn)
  fresh()
  local originalOpts = App.opts
  local originalIsReady = RomImporter.isReady
  local originalNew = FieldState.new
  local graphics = love.graphics
  local originalPrint = graphics.print
  local result = {
    prints = 0,
    captured = nil,
    state = countingState(),
  }
  App.opts = opts or {}
  RomImporter.isReady = ready
  FieldState.new = function(versionId, _, options)
    result.captured = { versionId = versionId, options = options }
    return result.state
  end
  graphics.print = function()
    result.prints = result.prints + 1
  end
  local ok, err = pcall(fn, result)
  App.opts = originalOpts
  RomImporter.isReady = originalIsReady
  FieldState.new = originalNew
  graphics.print = originalPrint
  if not ok then
    error(err, 0)
  end
  return result
end

-- An importer stand-in in a given state. App reads isBusy()/state and forwards
-- drops; a terminal (complete/error) stand-in models an importer left over
-- from a finished session.
local function importerStub(state, busy)
  local importer = {
    state = state,
    busy = busy or false,
    filedroppedCalls = 0,
  }
  function importer:isBusy()
    return self.busy
  end
  function importer:filedropped()
    self.filedroppedCalls = self.filedroppedCalls + 1
  end
  return importer
end

-- A minimal dropped-file stand-in satisfying RomSource.fromDroppedFile's
-- protocol. The bytes are not a ROM, so a real importer routes the drop into
-- its reading state without touching the filesystem or caches.
local function droppedFile()
  return {
    getFilename = function()
      return "dropped.nds"
    end,
    open = function()
      return true
    end,
    read = function()
      return "not a real rom"
    end,
    close = function() end,
  }
end

function T.set_state_disposes_previous_exactly_once()
  fresh()
  local first = countingState()
  local second = countingState()
  App.setState(first)
  App.setState(second)
  Assert.equal(first.disposed, 1)
  Assert.equal(second.disposed, 0)
  Assert.equal(App.state, second)
end

function T.set_state_without_dispose_replaces_without_error()
  fresh()
  App.setState({})
  local nextState = countingState()
  App.setState(nextState)
  Assert.equal(nextState.disposed, 0)
  Assert.equal(App.state, nextState)
end

-- App.quit is App.setState(nil): the first quit disposes the current state
-- and clears it, and any further quit is a safe no-op.
function T.quit_disposes_the_current_state_exactly_once_and_is_repeat_safe()
  fresh()
  local state = countingState()
  App.setState(state)
  App.quit()
  App.quit()
  Assert.equal(state.disposed, 1)
  Assert.isNil(App.state)
end

function T.quit_after_replacement_never_revisits_the_old_state()
  fresh()
  local first = countingState()
  local second = countingState()
  App.setState(first)
  App.setState(second)
  App.quit()
  Assert.equal(first.disposed, 1)
  Assert.equal(second.disposed, 1)
end

function T.input_callbacks_preserve_the_complete_host_argument_tuple()
  local joystick = {}
  local cases = {
    { "gamepadaxis", { joystick, "leftx", 0.75 } },
    { "mousepressed", { 12.5, 34.5, 1, true, 2 } },
    { "mousemoved", { 15.5, 36.5, 3, 2, false } },
    { "mousereleased", { 15.5, 36.5, 1, true, 2 } },
    { "wheelmoved", { 2, -3 } },
    { "touchpressed", { "finger-1", 3.5, 4.5, 0.25, 0.5, 0.8 } },
    { "touchmoved", { "finger-1", 5.5, 6.5, 0.25, 0.5, 0.8 } },
    { "touchreleased", { "finger-1", 5.5, 6.5, 0.25, 0.5, 0.8 } },
  }

  withInputState(function(calls)
    for _, case in ipairs(cases) do
      local name, expected = case[1], case[2]
      App[name](unpack(expected))
      local actual = calls[name]
      Assert.notNil(actual, "App." .. name .. " must reach the active state")
      Assert.equal(#actual, #expected, "App." .. name .. " must preserve every host argument")
      for index, value in ipairs(expected) do
        Assert.equal(actual[index], value, "App." .. name .. " argument " .. index .. " changed")
      end
    end
  end)
end

function T.resize_forwards_the_exact_tuple_only_to_resize_capable_states()
  fresh()
  local calls = {}
  App.setState({
    resize = function(_, width, height)
      calls[#calls + 1] = { width, height }
    end,
  })
  App.resize(1280, 720)
  Assert.deepEqual(calls, { { 1280, 720 } })

  App.setState({})
  Assert.isTrue(pcall(App.resize, 1280, 720), "states without resize remain a no-op")
  App.setState(nil)
end

function T.actor_preview_dispose_releases_exactly_once_and_is_repeat_safe()
  fresh()
  local released = {}
  local provider = {
    disposeCalls = 0,
    dispose = function(self)
      self.disposeCalls = self.disposeCalls + 1
    end,
    release = function(_, spriteId)
      released[#released + 1] = spriteId
    end,
  }
  local state = setmetatable({
    provider = provider,
    entries = { { spriteId = 1 }, { spriteId = 2 } },
  }, ActorPreviewState)
  state:dispose()
  state:dispose()
  Assert.equal(#released, 2)
  Assert.equal(provider.disposeCalls, 1)
end

function T.starting_an_import_disposes_the_active_field_state()
  fresh()
  local field = countingState()
  App.setState(field)
  App.saveDir = nil
  App._startImport()
  Assert.equal(field.disposed, 1)
  Assert.equal(getmetatable(App.state).__index, ImportState)
  Assert.notNil(App.importer)
end

-- The bare "g4recomp" draw is developer branding on an empty frame: product
-- mode draws nothing, dev mode keeps the emergency text.
function T.app_draw_keeps_the_emergency_brand_text_only_in_dev_mode()
  for _, dev in ipairs({ false, true }) do
    local result = withAppHarness({ dev = dev }, function()
      return false
    end, function()
      App.draw()
    end)
    local expected = 0
    if dev then
      expected = 1
    end
    Assert.equal(result.prints, expected, "brand text on an empty frame tracks dev mode")
  end
end

-- An import session is single-use. A file drop during gameplay after a
-- finished import (complete or failed) must enter a fresh import session
-- through the import state; the stale importer's completion callback would
-- otherwise replace the active field state unexpectedly, and re-running a
-- failed importer is just as wrong.
function T.drop_after_a_finished_import_starts_a_fresh_session()
  for _, terminalState in ipairs({ "complete", "error" }) do
    fresh()
    local stale = importerStub(terminalState)
    App.importer = stale
    App.setState({})
    App.filedropped(droppedFile())
    Assert.equal(stale.filedroppedCalls, 0, "the stale importer must not be invoked")
    Assert.isFalse(App.importer == stale, "a finished import session must not be reused")
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, ImportState)
    Assert.equal(App.state.importer, App.importer)
  end
end

-- Drops while an import is running are ignored: no new session, no forward to
-- the busy importer.
function T.drop_while_busy_is_ignored()
  fresh()
  local busy = importerStub("reading", true)
  App.importer = busy
  local state = {}
  App.setState(state)
  App.filedropped(droppedFile())
  Assert.equal(busy.filedroppedCalls, 0)
  Assert.equal(App.importer, busy)
  Assert.equal(App.state, state)
end

-- A failed import leaves no importer behind: the next update clears it, so a
-- stale reference can never survive the session. The import screen holds its
-- own reference and is unaffected.
function T.failed_import_is_cleared_on_the_next_update()
  fresh()
  App.importer = importerStub("error")
  local state = { update = function() end }
  App.setState(state)
  App.update(0.016)
  Assert.isNil(App.importer, "a failed import session must not linger")
  Assert.equal(App.state, state, "clearing the importer must not disturb the import screen")
end

-- The boot decision when no ROM was supplied: zero ready versions enter the
-- import state, one resumes its field session, and both offer the version
-- selector over exactly the ready array. These tests cover the whole boot
-- selection wiring -- version-selection has one owner, App itself.
-- RomImporter.isReady and FieldState.new are the seams: readiness is a pure
-- check and a real FieldState boot is ROM-gated.

function T.boot_existing_with_no_ready_version_starts_an_import()
  withAppHarness({}, function()
    return false
  end, function()
    App._bootExisting()
    Assert.notNil(App.importer)
    Assert.equal(getmetatable(App.state).__index, ImportState)
  end)
end

function T.boot_existing_with_one_ready_version_resumes_its_field_session()
  local result = withAppHarness({}, function(id)
    return id == "heartgold"
  end, function()
    App._bootExisting()
  end)
  local captured = result.captured
  Assert.notNil(captured)
  ---@cast captured table
  Assert.equal(captured.versionId, "heartgold")
  Assert.isTrue(captured.options.resumeSave)
  Assert.isFalse(captured.options.resetSave)
  Assert.isFalse(captured.options.development)
  Assert.equal(App.state, result.state)
end

-- The CLI session flags are applied once at the boot boundary: --dev reaches
-- the state as the presentation flag, and --new-field-session forces a fresh
-- session instead of a resume.
function T.boot_flags_flow_into_the_field_state_options()
  local result = withAppHarness({ dev = true, newFieldSession = true }, function(id)
    return id == "heartgold"
  end, function()
    App._bootExisting()
  end)
  local captured = result.captured
  Assert.notNil(captured)
  ---@cast captured table
  Assert.isTrue(captured.options.development, "--dev reaches the field state")
  Assert.isTrue(captured.options.resetSave, "--new-field-session forces a reset")
  Assert.isFalse(captured.options.resumeSave, "--new-field-session never resumes")
end

function T.boot_existing_with_two_ready_versions_offers_the_selector_over_the_ready_array()
  withAppHarness({}, function(id)
    return id == "heartgold" or id == "soulsilver"
  end, function(result)
    -- The selector's onPick callback reads App.opts through fieldSessionOptions,
    -- so boot and probe run inside the one fixture that installs them; every
    -- stub is restored on every path afterwards.
    App._bootExisting()
    Assert.isNil(result.captured, "the selector must not boot a field state")
    local selector = App.state
    ---@cast selector table
    Assert.equal(getmetatable(selector).__index, VersionSelectState)
    Assert.deepEqual(selector.ready, { "heartgold", "soulsilver" })
    selector.onPick("soulsilver")
    local picked = result.captured
    Assert.notNil(picked)
    ---@cast picked table
    Assert.equal(picked.versionId, "soulsilver")
    Assert.isTrue(picked.options.resumeSave)
    Assert.equal(App.state, result.state)
  end)
end

return { tests = T }
