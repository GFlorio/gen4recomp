-- Production-composed script-context conformance (D18): every public raw ctx
-- method and every registered task type exercised against the production
-- FieldScripts-composed graph. The conformance scripts and their raw handler
-- module are supplied through the production mod-asset seam
-- (`rawModules`/`modScripts` runtime options): they are assets, not
-- substituted services — the scheduler, the service adapters, the world
-- store, the dialogue host, the actor world, and the transition are the real
-- FieldRuntime/FieldScripts composition. Scenarios:
--
-- * CONF-01: one chain script drives every production-backed ctx method (the
--   in-band probe faults the instance with a named message on any mismatch)
--   and every ctx task factory through a real task record to completion,
--   including a scripted warp into TOWN.
-- * CONF-02: with no script hosts wired (the real App composition), events,
--   audio, and camera operations fault instead of silently succeeding, while
--   dialogue (always wired) keeps working.
-- * CONF-03: the live production task registry matches the declared
--   FieldScripts.TASK_MODULES set, every registered task satisfies the D16
--   registration invariants, and the factory tasks whose backing services are
--   absent (fade without a screen, sound_wait without a completion token)
--   fault with attribution instead of degrading.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local S = require("gen4.script")
local RawModules = require("libs.engine.src.script.RawModules")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local FieldRuntime = require("game.src.game.FieldRuntime")
-- TASK_MODULES is the D18 implementation contract: the module exports the
-- registered-task declaration the conformance derives its expectations from.
local FieldScriptsModule = require("game.src.game.FieldScripts") --[[@as table<string, any>]]

local T = {
  metadata = {
    layer = "acceptance",
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "conformance" },
  },
  tests = {},
}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"
local TOWN = "MAP_NEW_BARK"

-- --- The conformance raw module -------------------------------------------------

-- One handler per conformance leg. In-band checks raise with a named message
-- so a probe failure faults the instance with attribution; the scenario
-- asserts the fault stream is empty and the recorded variables hold the
-- expected production-backed values.
local function check(condition, name)
  if not condition then
    error("conformance probe failed: " .. name, 2)
  end
end

local Conformance = {}

-- The full public ctx surface against the production services: identity,
-- world flags/variables, instance locals, RNG, objects over the real actor
-- world, player facade (including the loud faults for the unwired profile),
-- dialogue/maps/audio/camera services (including the loud camera faults),
-- events through the wired host, log sink, and the trigger copy contract.
function Conformance.probe(ctx)
  check(ctx.script:id() == "acceptance.conformance", "script:id")
  check(type(ctx.script:instanceId()) == "string", "script:instanceId")
  check(ctx.script:owner().id == "acceptance.conformance", "script:owner")
  local t1 = ctx.script:trigger()
  local t2 = ctx.script:trigger()
  check(type(t1) == "table" and type(t2) == "table", "script:trigger returns tables")
  check(t1 ~= t2, "script:trigger must not hand out the live trigger table")
  check(t1.scriptId == "acceptance.conformance", "script:trigger carries the trigger scriptId")
  check(t2.scriptId == "acceptance.conformance", "script:trigger copy carries the trigger scriptId")
  ctx.variables:set(16403, t1 ~= t2 and 1 or 0)

  ctx.flags:set("FLAG_MAPTEMP_003")
  check(ctx.flags:get("FLAG_MAPTEMP_003"), "flags:set/get")
  ctx.flags:clear("FLAG_MAPTEMP_003")
  check(not ctx.flags:get("FLAG_MAPTEMP_003"), "flags:clear")
  ctx.variables:set("VAR_TEMP_x4004", 1)

  ctx.variables:set("VAR_TEMP_x4003", 5)
  ctx.variables:add("VAR_TEMP_x4003", 3)
  ctx.variables:sub("VAR_TEMP_x4003", 2)
  check(ctx.variables:get("VAR_TEMP_x4003") == 6, "variables:get/set/add/sub")

  ctx.locals:set("conform_tmp", 21)
  check(ctx.locals:get("conform_tmp") == 21, "locals:set/get")
  ctx.variables:set("VAR_TEMP_x4005", 1)

  local roll = ctx.random:nextInt(10)
  check(roll >= 0 and roll < 10, "random:nextInt bounds")
  local ranged = ctx.random:range(2, 4)
  check(ranged >= 2 and ranged <= 4, "random:range bounds")
  check(type(ctx.random:chance(1, 2)) == "boolean", "random:chance")
  ctx.variables:set("VAR_TEMP_x4006", 1)

  local elm = ctx.objects:require("map:61:object:0")
  check(elm:id() == "map:61:object:0", "objects:id")
  check(elm:mapId() == 61, "objects:mapId")
  local snapshot = elm:position()
  check(snapshot.fieldX == 6 and snapshot.fieldZ == 5, "objects:require/position")
  check(elm:facing() == "south", "objects:facing")
  check(elm:visible(), "objects:visible")
  ctx.objects:setFacing("map:61:object:0", "east")
  check(ctx.objects:get("map:61:object:0"):facing() == "east", "objects:setFacing")
  ctx.objects:setPosition("map:61:object:0", { fieldX = 6, fieldZ = 5 })
  local placed = ctx.objects:get("map:61:object:0"):position()
  check(placed.fieldX == 6 and placed.fieldZ == 5, "objects:setPosition")
  ctx.objects:hide("map:61:object:0")
  check(not ctx.objects:get("map:61:object:0"):visible(), "objects:hide")
  ctx.objects:show("map:61:object:0")
  check(ctx.objects:get("map:61:object:0"):visible(), "objects:show")
  check(ctx.objects:exists("map:61:object:0"), "objects:exists")
  check(ctx.objects:get("map:61:object:999") == nil, "objects:get missing -> nil")
  local missingOk, missingErr = pcall(function()
    ctx.objects:require("map:61:object:999")
  end)
  if missingOk or not Errors.is(missingErr) then
    check(false, "objects:require missing faults")
  else
    ---@cast missingErr Errors.Error
    check(missingErr.code == "SCRIPT_ACTOR_NOT_FOUND", "objects:require missing faults")
  end
  ctx.objects:setFacing("map:61:object:0", "south")
  ctx.variables:set("VAR_TEMP_x4007", 1)

  local playerPosition = ctx.player:position()
  check(playerPosition.fieldX == 4 and playerPosition.fieldZ == 13, "player:position")
  check(ctx.player:facing() == "north", "player:facing")
  check(ctx.player:isLocked() == false, "player:isLocked")
  local genderOk, genderErr = pcall(function()
    return ctx.player:gender()
  end)
  check(
    not genderOk and Errors.is(genderErr) and genderErr.code == "SCRIPT_SERVICE_MISSING",
    "player:gender faults without a wired profile"
  )
  local nameOk, nameErr = pcall(function()
    return ctx.player:name()
  end)
  check(
    not nameOk and Errors.is(nameErr) and nameErr.code == "SCRIPT_SERVICE_MISSING",
    "player:name faults without a wired profile"
  )
  ctx.variables:set("VAR_TEMP_x400A", 1)

  check(ctx.dialogue:isOpen() == false, "dialogue:isOpen before any box")
  ctx.variables:set("VAR_TEMP_x400D", 1)

  check(ctx.maps:currentId() == 61, "maps:currentId")
  check(ctx.maps:has("MAP_NEW_BARK"), "maps:has")
  local town = ctx.maps:resolve("MAP_NEW_BARK")
  check(town ~= nil and town.mapId == 60, "maps:resolve")
  ctx.variables:set("VAR_TEMP_x400F", 61)

  local playing = ctx.audio:isPlaying("SEQ_SE_DP_SELECT")
  check(type(playing) == "boolean", "audio:isPlaying consults the wired service")
  ctx.variables:set("VAR_TEMP_x4010", 1)

  local cameraOk, cameraErr = pcall(function()
    return ctx.camera:target()
  end)
  check(
    not cameraOk and Errors.is(cameraErr) and cameraErr.code == "SCRIPT_RAW_HANDLER_ERROR",
    "camera:target faults without a service"
  )
  local modeOk, modeErr = pcall(function()
    return ctx.camera:mode()
  end)
  check(
    not modeOk and Errors.is(modeErr) and modeErr.code == "SCRIPT_RAW_HANDLER_ERROR",
    "camera:mode faults without a service"
  )
  ctx.variables:set("VAR_TEMP_x4011", 1)

  ctx.events:emit("mod.acceptance.conformance.probe", { n = 1 })
  ctx.log:debug("conformance", {})
  ctx.log:info("conformance", {})
  ctx.log:warn("conformance", {})
  ctx.variables:set("VAR_TEMP_x4014", 1)
  return nil
end

-- --- The chain legs: one ctx task factory per leg ---------------------------------

function Conformance.waitTicksLeg(ctx)
  ctx.variables:set(16416, 1)
  return ctx.tasks.waitTicks({ ticks = 3 })
end

function Conformance.waitInputLeg(ctx)
  ctx.variables:set(16417, 1)
  return ctx.tasks.waitInput({ node = { buttons = { "a", "b" } } })
end

function Conformance.dialogueLeg(ctx)
  ctx.variables:set(16418, 1)
  return ctx.tasks.dialogue({ node = { message = "msg.hgss.0542.00009", bindings = {} } })
end

function Conformance.movementLeg(ctx)
  ctx.variables:set(16419, 1)
  return ctx.tasks.movement({
    actor = "map:61:object:0",
    sequence = { { action = "walk", direction = "north", tiles = 1, speed = "fast" } },
    blocking = true,
  })
end

function Conformance.barrierLeg(ctx)
  ctx.variables:set(16420, 1)
  return ctx.tasks.movementBarrier({ node = { scope = "environment" } })
end

function Conformance.childLeg(ctx)
  ctx.variables:set(16421, 1)
  return ctx.script:call("acceptance.helper", { value = 7 })
end

function Conformance.warpLeg(ctx)
  ctx.variables:set(16422, 1)
  local town = ctx.maps:resolve("MAP_NEW_BARK")
  local origin = town.coordinateOrigin
  return ctx.tasks.warp({
    node = {
      map = "MAP_NEW_BARK",
      warp = 0,
      fieldX = 683 - origin.x,
      fieldZ = 400 - origin.z,
      facing = "south",
    },
  })
end

function Conformance.done(ctx)
  ctx.variables:set(16423, 1)
  return nil
end

-- --- No-hosts legs (CONF-02) ------------------------------------------------------

-- Each operation must fault the instance: the marker node after the lua node
-- only runs when the operation silently succeeded (the current defect).
function Conformance.emitOnly(ctx)
  ctx.events:emit("mod.acceptance.conformance.probe", { n = 1 })
end

function Conformance.audioOnly(ctx)
  ctx.audio:isPlaying("SEQ_SE_DP_SELECT")
end

function Conformance.dialogueOpen(ctx)
  if ctx.dialogue:isOpen() ~= false then
    error("conformance probe failed: dialogue:isOpen before any box", 2)
  end
end

function Conformance.cameraOnly(ctx)
  ctx.camera:target()
end

-- --- Faulting factory legs (CONF-03) ------------------------------------------------

function Conformance.fadeLeg(ctx)
  return ctx.tasks.fade({})
end

function Conformance.soundWaitLeg(ctx)
  return ctx.tasks.soundWait({ node = { op = "wait_sound" } })
end

-- --- The mod assets ----------------------------------------------------------------

local conformanceScript = S.script({
  api = 1,
  id = "acceptance.conformance",
  steps = {
    S.lua({ module = "acceptance.conformance", fn = "probe" }),
    S.lua({ module = "acceptance.conformance", fn = "waitTicksLeg" }),
    S.lua({ module = "acceptance.conformance", fn = "waitInputLeg" }),
    S.lua({ module = "acceptance.conformance", fn = "dialogueLeg" }),
    S.lua({ module = "acceptance.conformance", fn = "movementLeg" }),
    S.lua({ module = "acceptance.conformance", fn = "barrierLeg" }),
    S.lua({ module = "acceptance.conformance", fn = "childLeg" }),
    S.lua({ module = "acceptance.conformance", fn = "warpLeg" }),
    S.lua({ module = "acceptance.conformance", fn = "done" }),
    S.stop(),
  },
})

local helperScript = S.script({
  api = 1,
  id = "acceptance.helper",
  params = { value = "integer" },
  steps = {
    S.setVar({ variable = 16424, value = S.arg("value") }),
    { op = "signal_caller" },
    S.stop(),
  },
})

-- The lua node runs first; the marker node after it only runs when the
-- operation did NOT fault, so an unset marker pins the attributed fault.
local function noHostsScript(id, fn, marker)
  return S.script({
    api = 1,
    id = id,
    steps = {
      S.lua({ module = "acceptance.conformance", fn = fn }),
      S.setVar({ variable = marker, value = 1 }),
      S.stop(),
    },
  })
end

local function faultScript(id, fn)
  return S.script({
    api = 1,
    id = id,
    steps = {
      S.lua({ module = "acceptance.conformance", fn = fn }),
      S.stop(),
    },
  })
end

local MOD_OWNER = { kind = "mod", id = "acceptance.conformance", api = 1 }

-- The production mod-asset seam (D18 implementation): `rawModules` is wired
-- as the runtime's raw-module registry and `modScripts` installs into the
-- script registry before it seals. The suite supplies both as assets.
local function conformanceFieldOptions()
  local modules = RawModules.new()
  modules:register("acceptance.conformance", Conformance, MOD_OWNER)
  return {
    rawModules = modules,
    modScripts = {
      { id = "acceptance.conformance", script = conformanceScript, owner = MOD_OWNER },
      { id = "acceptance.helper", script = helperScript, owner = MOD_OWNER },
      { id = "acceptance.faults.fade", script = faultScript("acceptance.faults.fade", "fadeLeg"), owner = MOD_OWNER },
      {
        id = "acceptance.faults.sound",
        script = faultScript("acceptance.faults.sound", "soundWaitLeg"),
        owner = MOD_OWNER,
      },
      {
        id = "acceptance.noHosts.emit",
        script = noHostsScript("acceptance.noHosts.emit", "emitOnly", 16425),
        owner = MOD_OWNER,
      },
      {
        id = "acceptance.noHosts.audio",
        script = noHostsScript("acceptance.noHosts.audio", "audioOnly", 16426),
        owner = MOD_OWNER,
      },
      {
        id = "acceptance.noHosts.dialogue",
        script = noHostsScript("acceptance.noHosts.dialogue", "dialogueOpen", 16427),
        owner = MOD_OWNER,
      },
      {
        id = "acceptance.noHosts.camera",
        script = noHostsScript("acceptance.noHosts.camera", "cameraOnly", 16428),
        owner = MOD_OWNER,
      },
    },
  }
end

-- --- Suite helpers ---------------------------------------------------------------

local function varValue(game, name)
  local world = game.runtime.scripts.worldState
  return world:getVar(name)
end

-- The production fault surface: scheduler script.error records through the
-- wired events host (the recording hosts the harness injects).
local function scriptFaults(game)
  local faults = {}
  for _, record in ipairs(game.hosts.events.records) do
    if record.name == "script.error" then
      faults[#faults + 1] = record.payload
    end
  end
  return faults
end

local function assertNoFaults(game, label)
  local faults = scriptFaults(game)
  Assert.equal(
    #faults,
    0,
    label
      .. ": the conformance script must not fault ("
      .. tostring(faults[1] and (faults[1].code .. ": " .. faults[1].message))
      .. ")"
  )
end

local function bootWithAssets(harness, versionId, map)
  return harness:boot({
    versionId = versionId,
    map = map,
    save = "fresh",
    fieldOptions = conformanceFieldOptions(),
  })
end

local function closeGame(game)
  if game then
    game:close()
  end
end

-- Close the booted game and re-raise the scenario error (or a dispose
-- error when the scenario itself passed). Never swallows either.
local function finishScenario(game, ok, err)
  local closeErr
  if game then
    local closeOk, cerr = pcall(closeGame, game)
    if not closeOk then
      closeErr = cerr
    end
  end
  if closeErr and ok then
    error(closeErr, 0)
  end
  if not ok then
    error(err, 0)
  end
end

-- CONF-01: the chain script exercises the full public ctx surface and every
-- ctx task factory through real task records in one production boot.
function T.tests.raw_context_methods_and_task_factories_conform_to_the_production_composed_graph()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game
    local ok, err = xpcall(function()
      game = bootWithAssets(harness, versionId, LAB)
      game:startScript("acceptance.conformance")

      -- The raw ctx probe completes on the first steps; a probe mismatch
      -- faults the instance with the failing check named in the message.
      game:advanceUntil("the raw ctx probe completes", function()
        return varValue(game, 16403) == 1 or #scriptFaults(game) > 0
      end, 60)
      assertNoFaults(game, "raw ctx probe")
      Assert.equal(varValue(game, "VAR_TEMP_x4003"), 6, "variables:get/set/add/sub through the real world store")
      Assert.equal(varValue(game, "VAR_TEMP_x400F"), 61, "maps:currentId")
      Assert.equal(varValue(game, 16403), 1, "script:trigger must hand out fresh copies")
      local emitted = false
      for _, record in ipairs(game.hosts.events.records) do
        if record.name == "mod.acceptance.conformance.probe" then
          emitted = true
        end
      end
      Assert.isTrue(emitted, "ctx.events:emit must reach the wired events host")

      -- wait_ticks leg, then the chain advances to the wait_input leg.
      game:advanceUntil("the wait_ticks task phase marker", function()
        return varValue(game, 16416) == 1
      end, 60)
      game:advanceUntil("the wait_input phase marker after wait_ticks completes", function()
        return varValue(game, 16417) == 1
      end, 60)

      -- wait_input leg: one action edge completes it.
      game:pressAction()
      game:advanceUntil("the dialogue phase marker after wait_input completes", function()
        return varValue(game, 16418) == 1
      end, 60)

      -- dialogue leg: the real message box opens through the production host.
      local opened = game:advanceUntil("the raw dialogue task opens a real message box", function(snapshot)
        return snapshot.dialogue.modal
      end, 60)
      Assert.equal(opened.dialogue.messageId, 9)
      local closedSteps = 0
      while varValue(game, 16419) ~= 1 and closedSteps < 480 do
        if game:snapshot().dialogue.modal then
          game:pressAction()
        else
          game:step()
        end
        closedSteps = closedSteps + 1
      end
      Assert.equal(varValue(game, 16419), 1, "the movement phase marker after dialogue completes")
      Assert.isFalse(game:snapshot().dialogue.modal, "the raw dialogue box must close")

      -- movement leg: elm walks one tile north through the real actor world.
      game:advanceUntil("the raw movement task walks elm north", function(snapshot)
        local elm = snapshot.actors["map:61:object:0"]
        return elm ~= nil and elm.fieldX == 6 and elm.fieldZ == 4
      end, 120)
      game:advanceUntil("the barrier phase marker after movement completes", function()
        return varValue(game, 16420) == 1
      end, 60)

      -- barrier and child_script legs: the child runs through the real
      -- common-child slot machinery and writes its argument to the store.
      game:advanceUntil("the child phase marker after the barrier completes", function()
        return varValue(game, 16421) == 1
      end, 60)
      game:advanceUntil("the helper child script writes its value", function()
        return varValue(game, 16424) == 7
      end, 60)
      game:advanceUntil("the warp phase marker after the child_script task completes", function()
        return varValue(game, 16422) == 1
      end, 60)

      -- warp leg: the scripted warp crosses into TOWN and the script finishes
      -- there, releasing every owner.
      game:advanceUntil("the raw warp task lands in TOWN and the script finishes", function(snapshot)
        return snapshot.mapId == 60
          and varValue(game, 16423) == 1
          and not snapshot.fieldLocked
          and not snapshot.dialogue.modal
      end, 480)
      local final = game:snapshot()
      Assert.equal(final.player.fieldX, 683, "warp destination fieldX")
      Assert.equal(final.player.fieldZ, 400, "warp destination fieldZ")
      assertNoFaults(game, "conformance chain")
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    finishScenario(game, ok, err)
  end)
end

-- CONF-02: the App composition wires no script hosts. Every operation that
-- needs an absent service must fault instead of silently succeeding; the
-- dialogue service is always wired and keeps working.
function T.tests.events_audio_and_camera_fault_when_their_services_are_not_wired()
  local harness = AcceptanceHarness.new({
    runtimeFactory = function(versionId, map, runtimeOptions)
      runtimeOptions.scriptHosts = nil
      return FieldRuntime.new(versionId, map, runtimeOptions)
    end,
  })
  harness:forEachVersion(function(versionId)
    local game
    local ok, err = xpcall(function()
      game = bootWithAssets(harness, versionId, LAB)

      -- events: emit without an events service must fault; the marker node
      -- after the lua node never runs (it runs today — the silent success).
      game:startScript("acceptance.noHosts.emit")
      game:advanceUntil("the emit script ends without holding the field", function(snapshot)
        return not snapshot.fieldLocked
      end, 60)
      Assert.equal(
        varValue(game, 16425),
        0,
        "ctx.events:emit without an events service must fault, not silently succeed"
      )

      -- audio: isPlaying without an audio service must fault, not return false.
      game:startScript("acceptance.noHosts.audio")
      game:advanceUntil("the audio script ends without holding the field", function(snapshot)
        return not snapshot.fieldLocked
      end, 60)
      Assert.equal(
        varValue(game, 16426),
        0,
        "ctx.audio:isPlaying without an audio service must fault, not silently return false"
      )

      -- dialogue isOpen: the dialogue service is always wired; the script
      -- completes with the real controller status.
      game:startScript("acceptance.noHosts.dialogue")
      game:advanceUntil("the dialogue isOpen script completes", function()
        return varValue(game, 16427) == 1
      end, 60)

      -- camera: the unwired camera service keeps faulting (regression pin).
      game:startScript("acceptance.noHosts.camera")
      game:advanceUntil("the camera script ends without holding the field", function(snapshot)
        return not snapshot.fieldLocked
      end, 60)
      Assert.equal(varValue(game, 16428), 0, "ctx.camera:target without a service must fault")
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    finishScenario(game, ok, err)
  end)
end

-- CONF-03: the live production task registry matches the declared module
-- list and every registration satisfies the D16 invariants; the factory
-- tasks whose backings are absent fault with attribution instead of
-- degrading into fake completion.
function T.tests.every_registered_task_type_is_declared_and_reachable()
  local harness = AcceptanceHarness.new()
  harness:forEachVersion(function(versionId)
    local game
    local ok, err = xpcall(function()
      game = bootWithAssets(harness, versionId, LAB)
      local scripts = game.runtime.scripts

      -- The declared module list is the conformance source of truth: the
      -- production composition must export it and expose the live registry.
      local declared =
        assert(FieldScriptsModule.TASK_MODULES, "the production composition must export FieldScripts.TASK_MODULES")
      local expected = {}
      for _, moduleName in ipairs(declared) do
        expected[require(moduleName).type] = true
      end
      expected["actor_pause"] = true
      local registry = assert(scripts.taskRegistry, "the production composition must expose its task registry")
      local types = assert(registry.types and registry:types(), "the task registry must enumerate its types")
      local missing = {}
      for _, taskType in ipairs(types) do
        if expected[taskType] then
          expected[taskType] = nil
        else
          missing[#missing + 1] = taskType
        end
      end
      local undeclared = {}
      for taskType in pairs(expected) do
        undeclared[#undeclared + 1] = taskType
      end
      table.sort(undeclared)
      Assert.equal(#missing, 0, "registry types not declared in TASK_MODULES: " .. table.concat(missing, ", "))
      Assert.equal(
        #undeclared,
        0,
        "declared task types absent from the production registry: " .. table.concat(undeclared, ", ")
      )
      for _, taskType in ipairs(types) do
        local impl = assert(registry:resolve(taskType, 1), "registered task must resolve at version 1: " .. taskType)
        Assert.equal(impl.version, math.floor(impl.version), "task version must be an integer: " .. taskType)
        Assert.equal(type(impl.validate), "function", "task validate is required: " .. taskType)
        Assert.equal(type(impl.create), "function", "task create is required: " .. taskType)
      end

      -- fade without a screen service faults with attribution.
      game:startScript("acceptance.faults.fade")
      game:advanceUntil("the fade fault releases the field", function(snapshot)
        return not snapshot.fieldLocked
      end, 60)
      local fadeFault = assert(scriptFaults(game)[1], "the fade factory must fault")
      Assert.equal(fadeFault.code, "SCRIPT_SERVICE_MISSING")

      -- sound_wait without a completion token faults with attribution (the
      -- second fault record: the fade fault above precedes it).
      game:startScript("acceptance.faults.sound")
      game:advanceUntil("the sound_wait fault releases the field", function(snapshot)
        return not snapshot.fieldLocked
      end, 60)
      local soundFault = assert(scriptFaults(game)[2], "the sound_wait factory must fault")
      Assert.equal(soundFault.code, "SCRIPT_TASK_UNSERIALIZABLE")
      Assert.equal(game:renderAttempts(), 0)
    end, debug.traceback)
    finishScenario(game, ok, err)
  end)
end

return T
