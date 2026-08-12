-- Production-composed persistence and lifecycle contracts. The shared
-- harness must carry saves between non-rendering runtime boots; tests never
-- restore FieldSave or construct a field subsystem themselves.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "persistence", "lifecycle" },
  },
  tests = {},
}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN = "MAP_NEW_BARK"

local function requireCapability(value, name)
  Assert.isTrue(
    type(value[name]) == "function",
    "acceptance harness must expose " .. name .. " for production persistence"
  )
end

local function withGame(map, fn)
  if fn == nil then
    fn = map
    map = LAB
  end
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", map = map, save = "fresh" })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function restart(game, options)
  requireCapability(game, "restart")
  return game:restart(options)
end

-- DET-02 helper: confirm edges like the harness's advanceDialogue, but stop
-- at the first mid-script boundary — no modal box open while the foreground
-- script still holds field control. One further tick lands on the live
-- wait_input task (the dialogue task completes one tick before the handoff
-- creates it), so the save captures the blocked instance with its live task
-- record.
local function confirmToMidScriptBoundary(game)
  for _ = 1, 480 do
    local snapshot = game:snapshot()
    if not snapshot.dialogue.modal then
      if snapshot.fieldLocked then
        game:step()
        local boundary = game:snapshot()
        assert(
          not boundary.dialogue.modal and boundary.fieldLocked,
          "mid-script boundary must hold field control with no modal box"
        )
        return boundary
      end
      error("foreground script released field control before a mid-script boundary", 2)
    end
    game:pressAction()
  end
  error("no mid-script boundary within 480 confirm edges", 2)
end

-- SAVE-02: a process-like runtime restart restores durable player and world
-- facts through FieldRuntime's normal resume path.
function T.tests.restart_resumes_location_avatar_and_world_state()
  withGame(function(game)
    requireCapability(game, "setWorldState")
    game:moveTo({ fieldX = 6, fieldZ = 6 })
    game:face("north")
    game:setWorldState({ flag = 100, variable = 7, value = 7 })
    local before = game:snapshot()
    local resumed = restart(game, { save = "resume" })
    local after = resumed:snapshot()
    Assert.deepEqual(after.player, before.player)
    Assert.deepEqual(after.world, { flags = { [100] = true }, variables = { [7] = 7 } })
    Assert.notNil(after.avatarId)
  end)
end

-- SAVE-01/06: disposal is the production save boundary and the failed-save
-- path is visible there. A failed write must be reported at the runtime
-- boundary without turning a later close into a second save or false success.
function T.tests.disposal_saves_once_and_a_failed_save_is_visible_without_double_disposal()
  withGame(function(game)
    requireCapability(game, "failNextSave")
    game:failNextSave()
    local result = restart(game, { save = "resume" })
    Assert.isTrue(result.saveStatus:find("Save failed:", 1, true) ~= nil)
    Assert.equal(result.lifecycle.saveWrites, 1)
    Assert.equal(result.lifecycle.runtimeDisposals, 1)
  end)
end

-- DET-02: a save captured mid-script (the bound New Bark woman script
-- holding field control at its wait_input prompt, after its real message
-- closed) must restore through the recomputed revision path: the resumed
-- script resumes at its real prompt — there is no placeholder anymore —
-- and completes releasing field control.
function T.tests.mid_script_restart_resumes_through_recomputed_revisions()
  withGame(TOWN, function(game)
    requireCapability(game, "moveTo")
    requireCapability(game, "face")
    requireCapability(game, "pressAction")
    requireCapability(game, "interaction")
    requireCapability(game, "advanceUntil")
    game:moveTo({ fieldX = 683, fieldZ = 400 })
    game:face("north")
    game:pressAction()
    Assert.equal(game:interaction().scriptId, "new_bark.npc.woman_1")
    -- The fresh-save conversation opens its real first message
    -- (msg.hgss.0542.00009) through the bound script, not a placeholder.
    local opened = game:advanceUntil("woman script opens its real first message", function(snapshot)
      return snapshot.dialogue.modal
    end, 120)
    Assert.isTrue(opened.fieldLocked)
    Assert.equal(opened.dialogue.messageId, 9)
    -- The save boundary: after the first box closes the script still holds
    -- field control at its wait_input prompt.
    local boundary = confirmToMidScriptBoundary(game)
    Assert.isTrue(boundary.fieldLocked)
    Assert.isFalse(boundary.dialogue.modal)
    local resumed = restart(game, { save = "resume" })
    Assert.equal(resumed.saveStatus, "Resumed saved field session")
    -- Foreground environment restored: the live task record survives the
    -- restart through the recomputed-revision path.
    Assert.isTrue(resumed:snapshot().fieldLocked)
    -- The resumed script continues at its real wait_input prompt: no
    -- placeholder box reopens (there is no placeholder anymore), and the
    -- next confirm edge completes the flow and releases field control.
    Assert.isFalse(resumed:snapshot().dialogue.modal)
    resumed:pressAction()
    local done = resumed:advanceUntil("resumed script completes and releases field control", function(snapshot)
      return not snapshot.dialogue.modal and not snapshot.fieldLocked
    end, 480)
    Assert.isFalse(done.dialogue.modal)
    Assert.isFalse(done.fieldLocked)
  end)
end

-- SAVE-07: the game autosaves after every completed warp, and warp
-- destinations can be any compiled map -- not only the two spawn-manifest
-- maps. A resume must restore from the save record alone: the spawn manifest
-- gates fresh boots only, or the game would produce saves it cannot load
-- (walk into a New Bark house, autosave, restart, and the boot fails).
-- SAVE-07: the game autosaves after every completed warp, and warp
-- destinations can be any compiled map -- not only the two spawn-manifest
-- maps. A resume must restore from the save record alone: the spawn manifest
-- gates fresh boots only, or the game would produce saves it cannot load
-- (walk into a New Bark house, autosave, restart, and the boot fails).
function T.tests.resume_restores_a_save_on_a_map_without_a_declared_spawn()
  withGame(TOWN, function(game)
    requireCapability(game, "moveTo")
    requireCapability(game, "waitForTransition")
    -- The Elms Lab 2F door warp is the only TOWN exit whose tile is walkable;
    -- its destination map (62) has no spawn-manifest entry.
    game:moveTo({ fieldX = 688, fieldZ = 392 })
    local transition = game:waitForTransition()
    Assert.equal(transition.destination.mapSymbol, "MAP_NEW_BARK_ELMS_LAB_2F")
    local before = game:snapshot()
    local resumed = restart(game, { save = "resume" })
    Assert.equal(resumed.saveStatus, "Resumed saved field session")
    local after = resumed:snapshot()
    Assert.equal(after.mapSymbol, "MAP_NEW_BARK_ELMS_LAB_2F")
    Assert.deepEqual(after.player, before.player)
  end)
end

-- A compact source-faithful three-choice vanilla menu (749--752 flow): the
-- post-resume script that proves lazy on-demand decode through production
-- composition. Its second value is 1, so selection is observably distinct.
local VANILLA_MENU = "vanilla.hgss.scr_seq.0003.script_056"
local RESULT_VARIABLE = 32780

local function menuIsModal(snapshot)
  return snapshot.menu ~= nil and snapshot.menu.modal == true
end

local function itemCenter(snapshot, itemIndex)
  local menu = assert(snapshot.menu, "field menu snapshot is required")
  local rect = assert(menu.itemRects[itemIndex], "field menu item rectangle is required")
  return rect.x + rect.width / 2, rect.y + rect.height / 2
end

-- REG-SNAP-01: the full snapshot cycle through production composition. A
-- forced snapshot miss boots lazily with the background warm-up running
-- during play; the save finishes the warm-up, computes the fingerprint, and
-- publishes the snapshot; the resume boot reuses it and then decodes a real
-- generated script on first use.
function T.tests.resume_reuses_the_registry_snapshot_after_a_saved_session()
  CacheFs.forVersion("heartgold"):remove("data/generated/script/registry.lua")
  local game = AcceptanceHarness.new():boot({ versionId = "heartgold", map = LAB, save = "fresh" })
  local ok, err = xpcall(function()
    game:moveTo({ fieldX = 6, fieldZ = 6 })
    game:face("north")
    local before = game:snapshot()
    local resumed = restart(game, { save = "resume" })
    Assert.deepEqual(resumed:snapshot().player, before.player)
    local scripts = resumed.runtime.scripts
    Assert.isTrue(scripts.registrySnapshotUsed, "resume boot must reuse the persisted registry snapshot")
    local snapshot = CacheFs.forVersion("heartgold"):loadLua("data/generated/script/registry.lua")
    Assert.notNil(snapshot, "registry snapshot file must exist after a saved session")
    ---@cast snapshot table
    Assert.equal(snapshot.schema, "g4-registry-snapshot-v1")
    Assert.isTrue(snapshot.key:match("^[0-9a-f]+$") ~= nil, "snapshot key must be a hex digest")
    Assert.isTrue(snapshot.fingerprint:match("^[0-9a-f]+$") ~= nil, "snapshot fingerprint must be a hex digest")

    -- The snapshot-hit resume decodes generated scripts lazily on first
    -- use: a real 749--752 menu starts, opens, accepts a pointer selection,
    -- and commits its script-owned value.
    resumed:startScript(VANILLA_MENU)
    resumed:step()
    local opened = resumed:advanceUntil("vanilla field menu becomes modal", menuIsModal, 120)
    local x, y = itemCenter(opened, 1)
    resumed.runtime.input:pointerDown("mouse:1", x, y)
    resumed:step()
    resumed.runtime.input:pointerUp("mouse:1", x, y)
    resumed:advanceUntil("menu closes after selection", function(snapshot)
      return snapshot.menu ~= nil and not snapshot.menu.modal
    end, 120)
    Assert.equal(resumed.runtime.scripts.worldState:getVar(RESULT_VARIABLE), 1)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
