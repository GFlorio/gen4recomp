-- Production-composed persistence and lifecycle contracts. The shared
-- harness must carry saves between non-rendering runtime boots; tests never
-- restore FieldSave or construct a field subsystem themselves.

local Assert = require("tests.support.Assert")
local LuaWriter = require("libs.codec.src.LuaWriter")
local CacheFs = require("libs.storage.src.CacheFs")
local FieldSave = require("libs.engine.src.FieldSave")
local ScriptSave = require("libs.engine.src.script.ScriptSave")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldScenarioManifest = require("data.manifests.field_scenario")

local T = {
  metadata = {
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

-- The scripts bucket of a real empty capture: deep-valid per ScriptSave, with
-- the live runtime's registry fingerprints so the planted save cannot be
-- rejected for a fingerprint mismatch instead of the planted defect.
local function validScriptsBucket(game)
  return {
    schema = ScriptSave.SCHEMA_NAME,
    registryFingerprint = game.runtime.scripts:registryFingerprint(),
    taskFingerprint = game.runtime.scripts.scheduler:taskRegistryFingerprint(),
    capturedAtSimulationTick = 0,
    nextEnvironmentId = 1,
    nextInstanceId = 1,
    nextTaskId = 1,
    environments = {},
    instances = {},
    tasks = {},
  }
end

-- Plant a structurally otherwise-valid field save at the live save path of
-- the acceptance namespace, over the fresh spawn state; `overrides` replace
-- record fields (position offsets make a wrongly restored boot observable).
local function plantSave(game, overrides)
  local fresh = game:snapshot()
  local record = {
    schema = FieldSave.SCHEMA,
    versionId = game.versionId,
    mapId = fresh.mapId,
    fieldX = fresh.player.fieldX,
    fieldZ = fresh.player.fieldZ,
    worldY = fresh.player.worldY,
    surfaceId = fresh.player.surfaceId,
    terrainDependencyHash = game.runtime.runtimeMap.terrainDependencyHash,
    facing = "south",
    avatar = "hero",
    scenario = FieldScenarioManifest.id,
    world = { flags = {}, variables = {}, objects = {}, rng = { state = 1, calls = 0 } },
    scripts = validScriptsBucket(game),
    auxiliaryUi = { requested = "shown", state = "shown" },
    playerData = {
      profile = { name = "GOLD", gender = 0, trainerId = 0 },
      options = { textFrame = 0, textSpeed = "mid" },
    },
  }
  for key, value in pairs(overrides) do
    record[key] = value
  end
  love.filesystem.createDirectory(game.saveNamespace)
  love.filesystem.write(game.saveNamespace .. "/" .. FieldSave.PATH, LuaWriter.encode(record))
  return record
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

-- SAVE-08: a save that exists but cannot be read must be distinguishable from
-- a missing save at the resume boundary. The runtime just wrote the file on
-- disposal, then the injected filesystem I/O failure hits the resume read; if
-- the load boundary reclassified that read failure as "file missing", the
-- session would silently restart fresh and discard the user's save without
-- notice. The failure is the harness's own save-root host boundary.
function T.tests.resume_reports_a_save_read_failure_instead_of_treating_it_as_missing()
  withGame(function(game)
    requireCapability(game, "failNextRead")
    game:moveTo({ fieldX = 6, fieldZ = 6 })
    game:failNextRead()
    local resumed = restart(game, { save = "resume" })
    Assert.equal(resumed.lifecycle.saveReads, 1, "the resume boot must have read the save exactly once")
    Assert.notNil(
      resumed.saveStatus,
      "a save that exists but cannot be read must be reported at the resume boundary, not silently treated as a fresh session"
    )
    Assert.isTrue(
      resumed.saveStatus:find("Save ignored:", 1, true) ~= nil,
      "the resume boundary must present the read failure as 'Save ignored: ...', got " .. tostring(resumed.saveStatus)
    )
  end)
end

-- A save that loads raw but is structurally invalid reaches the restore
-- boundary, is rejected with a typed FIELD_SAVE_* error, and the runtime
-- treats it as ignored: the resume boot lands on the fresh spawn with the
-- initial player manifest, never the corrupted record's state.
function T.tests.corrupt_save_is_ignored_and_fresh_state_boots()
  withGame(LAB, function(game)
    requireCapability(game, "failNextSave")
    local fresh = game:snapshot()
    -- Plant a structurally invalid record at the live save path: the rng
    -- bucket is malformed, and the location/facing differ from the fresh
    -- spawn so a corrupted boot would be observable.
    love.filesystem.createDirectory(game.saveNamespace)
    love.filesystem.write(
      game.saveNamespace .. "/" .. FieldSave.PATH,
      LuaWriter.encode({
        schema = FieldSave.SCHEMA,
        versionId = "heartgold",
        mapId = fresh.mapId,
        fieldX = fresh.player.fieldX + 1,
        fieldZ = fresh.player.fieldZ + 1,
        worldY = 0,
        surfaceId = 0,
        terrainDependencyHash = "corrupted",
        facing = "south",
        avatar = "hero",
        scenario = FieldScenarioManifest.id,
        world = { flags = {}, variables = {}, objects = {}, rng = {} },
        scripts = {},
        auxiliaryUi = { requested = "shown", state = "shown" },
        playerData = {
          profile = { name = "GOLD", gender = 0, trainerId = 0 },
          options = { textFrame = 0, textSpeed = "mid" },
        },
      })
    )
    -- The disposal write at restart would overwrite the planted file; fault
    -- it so the resume boot reads the corrupted record.
    game:failNextSave()
    local resumed = restart(game, { save = "resume" })
    Assert.equal(
      resumed.lifecycle.saveReads,
      1,
      "the corrupted save must be read exactly once, got " .. tostring(resumed.lifecycle.saveReads)
    )
    Assert.isTrue(
      resumed.runtime.saveStatus:find("Save ignored:", 1, true) ~= nil,
      "the resume boundary must present the corrupted save as ignored, got " .. tostring(resumed.runtime.saveStatus)
    )
    Assert.isTrue(
      resumed.runtime.saveStatus:find("FIELD_SAVE_WORLD_INVALID", 1, true) ~= nil,
      "the ignored save must carry the typed FIELD_SAVE_* error"
    )
    Assert.deepEqual(
      resumed:snapshot().player,
      fresh.player,
      "a corrupted save must boot the fresh spawn state, never the corrupted record"
    )
    Assert.equal(resumed.runtime.playerData.profile.name, "GOLD", "the fresh boot owns the initial player manifest")
  end)
end

-- A save naming a player graphic outside the compiled avatar set must be
-- rejected by FieldSave.restore through the runtime's own resume wiring (the
-- same validation record the save store receives), reported as ignored, and
-- fall back to the fresh spawn instead of crashing runtime construction.
function T.tests.resume_ignores_a_save_with_an_unknown_compiled_avatar()
  withGame(function(game)
    requireCapability(game, "failNextSave")
    local fresh = game:snapshot()
    plantSave(game, {
      avatar = "not-a-compiled-avatar",
      fieldX = fresh.player.fieldX + 1,
      fieldZ = fresh.player.fieldZ + 1,
    })
    -- The disposal write at restart would overwrite the planted file; fault
    -- it so the resume boot reads the planted record.
    game:failNextSave()
    local resumed = restart(game, { save = "resume" })
    Assert.equal(
      resumed.lifecycle.saveReads,
      1,
      "the invalid-avatar save must be read exactly once, got " .. tostring(resumed.lifecycle.saveReads)
    )
    Assert.isTrue(
      resumed.runtime.saveStatus:find("Save ignored:", 1, true) ~= nil,
      "the resume boundary must present the invalid avatar as ignored, got " .. tostring(resumed.runtime.saveStatus)
    )
    Assert.isTrue(
      resumed.runtime.saveStatus:find("FIELD_SAVE_AVATAR_INVALID", 1, true) ~= nil,
      "the ignored save must carry the typed avatar validation error, got " .. tostring(resumed.runtime.saveStatus)
    )
    Assert.deepEqual(
      resumed:snapshot().player,
      fresh.player,
      "an unknown compiled avatar must boot the fresh spawn state, never the corrupted record"
    )
  end)
end

-- A scripts bucket that passes the outer table shape but fails deep
-- ScriptSave.validate must be rejected at the restore boundary with the
-- scripts attribution, ignored, and fall back to the fresh spawn. The planted
-- environment record carries an impossible mode; everything else is a valid
-- empty capture, so only the deep validation can reject it.
function T.tests.resume_ignores_a_save_with_a_deeply_malformed_scripts_bucket()
  withGame(function(game)
    requireCapability(game, "failNextSave")
    local fresh = game:snapshot()
    local scripts = validScriptsBucket(game)
    scripts.environments = { { environmentId = "env:0", mode = "impossible" } }
    plantSave(game, {
      fieldX = fresh.player.fieldX + 1,
      fieldZ = fresh.player.fieldZ + 1,
      scripts = scripts,
    })
    -- The disposal write at restart would overwrite the planted file; fault
    -- it so the resume boot reads the planted record.
    game:failNextSave()
    local resumed = restart(game, { save = "resume" })
    Assert.equal(
      resumed.lifecycle.saveReads,
      1,
      "the malformed-scripts save must be read exactly once, got " .. tostring(resumed.lifecycle.saveReads)
    )
    Assert.isTrue(
      resumed.runtime.saveStatus:find("Save ignored:", 1, true) ~= nil,
      "the resume boundary must present the malformed scripts bucket as ignored, got "
        .. tostring(resumed.runtime.saveStatus)
    )
    Assert.isTrue(
      resumed.runtime.saveStatus:find("FIELD_SAVE_SCRIPTS_INVALID", 1, true) ~= nil,
      "the ignored save must carry the typed scripts validation error, got " .. tostring(resumed.runtime.saveStatus)
    )
    Assert.deepEqual(
      resumed:snapshot().player,
      fresh.player,
      "a malformed scripts bucket must boot the fresh spawn state, never the corrupted record"
    )
  end)
end

-- SAVE-09: the live save filename is the current semantic name, and an
-- obsolete development save at the old filename is never read as current.
-- The first restart round-trips the real session through the production save
-- path, which must land at the semantic filename. A stale file planted at the
-- obsolete name afterwards must not replace the real session on the next
-- resume: the restart's disposal write is faulted so it cannot overwrite the
-- planted file before the resume read; a runtime that consumed the obsolete
-- name would restore the planted facing instead of the session's.
function T.tests.obsolete_save_filename_is_not_read_as_the_current_save()
  withGame(function(game)
    requireCapability(game, "failNextSave")
    game:moveTo({ fieldX = 6, fieldZ = 6 })
    game:face("north")
    local resumed = restart(game, { save = "resume" })
    Assert.equal(resumed.saveStatus, "Resumed saved field session")
    Assert.equal(resumed:snapshot().player.facing, "north")
    local before = resumed:snapshot()
    love.filesystem.write(
      resumed.saveNamespace .. "/field-session-v1.lua",
      LuaWriter.encode({
        schema = FieldSave.SCHEMA,
        versionId = "heartgold",
        mapId = before.mapId,
        fieldX = before.player.fieldX,
        fieldZ = before.player.fieldZ,
        worldY = before.player.worldY,
        surfaceId = before.player.surfaceId,
        terrainDependencyHash = resumed.runtime.runtimeMap.terrainDependencyHash,
        facing = "south",
        avatar = before.avatarId,
        scenario = FieldScenarioManifest.id,
        world = resumed.runtime.scripts.worldState:capture(),
        auxiliaryUi = { requested = "shown", state = "shown" },
      })
    )
    resumed:failNextSave()
    local again = restart(resumed, { save = "resume" })
    Assert.equal(
      again:snapshot().player.facing,
      "north",
      "an obsolete field-session-v1.lua must never be read as the current save"
    )
    Assert.notNil(
      love.filesystem.getInfo(resumed.saveNamespace .. "/field-session.lua"),
      "the live save must be written at the current semantic filename"
    )
    love.filesystem.remove(resumed.saveNamespace .. "/field-session-v1.lua")
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

-- The game autosaves after every completed warp, and warp
-- destinations can be any compiled map -- not only the two spawn-manifest
-- maps. A resume must restore from the save record alone: the spawn manifest
-- gates fresh boots only, or the game would produce saves it cannot load
-- (walk into a New Bark house, autosave, restart, and the boot fails).
function T.tests.resume_restores_a_save_on_a_map_without_a_declared_spawn()
  withGame(TOWN, function(game)
    requireCapability(game, "moveTo")
    requireCapability(game, "face")
    requireCapability(game, "waitForTransition")
    -- The Elms Lab 2F door warp is the only TOWN exit whose tile is walkable;
    -- its destination map (62) has no spawn-manifest entry. The warp is a
    -- direction-gated tile (WARP_WEST): it fires on the input path, pressing
    -- west while standing on it.
    game:moveTo({ fieldX = 688, fieldZ = 392 })
    game:face("west")
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
