-- Audio, fade, and warp adapter tests :
-- sound waits with completing and fallback backends, the fade task, the
-- warp task integrated with the maps service, and the same-tick music and
-- camera operations. the target select sound works and
-- imported fade/warp nodes have stable semantics.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local S = require("gen4.script")
local Registry = require("libs.engine.src.script.Registry")
local Composition = require("libs.engine.src.script.Composition")
local TaskRegistry = require("libs.engine.src.script.TaskRegistry")
local Scheduler = require("libs.engine.src.script.Scheduler")
local WaitTicksTask = require("libs.engine.src.script.tasks.WaitTicksTask")
local SoundWaitTask = require("libs.engine.src.script.tasks.SoundWaitTask")
local FadeTask = require("libs.engine.src.script.tasks.FadeTask")
local WarpTask = require("libs.engine.src.script.tasks.WarpTask")
local FakeServices = require("tests.support.script.FakeServices")

local T = {}

---@class FakeAudioBackend
---@field playing table<string, boolean>
---@field music table<string, boolean>
---@field calls table[]
local FakeAudioBackend = {}
FakeAudioBackend.__index = FakeAudioBackend

function FakeAudioBackend.new()
  return setmetatable({ playing = {}, music = {}, calls = {} }, FakeAudioBackend)
end

function FakeAudioBackend:play(id)
  self.playing[id] = true
  self.calls[#self.calls + 1] = { op = "play", id = id }
end

function FakeAudioBackend:stop(id)
  self.playing[id] = nil
end

function FakeAudioBackend:playMusic(id)
  self.calls[#self.calls + 1] = { op = "playMusic", id = id }
end

function FakeAudioBackend:stopMusic(id)
  self.calls[#self.calls + 1] = { op = "stopMusic", id = id }
end

function FakeAudioBackend:resetMusic()
  self.calls[#self.calls + 1] = { op = "resetMusic" }
end

function FakeAudioBackend:temporaryMusic(id)
  self.calls[#self.calls + 1] = { op = "temporaryMusic", id = id }
end

function FakeAudioBackend:fadeMusicOut(spec)
  self.calls[#self.calls + 1] = { op = "fadeMusicOut", spec = spec }
end

function FakeAudioBackend:fadeMusicIn(spec)
  self.calls[#self.calls + 1] = { op = "fadeMusicIn", spec = spec }
end

function FakeAudioBackend:isPlaying(id)
  return self.playing[id] == true
end

function FakeAudioBackend:currentEffect()
  for id in pairs(self.playing) do
    return id
  end
  return nil
end

function FakeAudioBackend:playCry(species, form)
  local token = "cry:" .. tostring(species)
  self.playing[token] = true
  self.calls[#self.calls + 1] = { op = "playCry", species = species, form = form }
end

function FakeAudioBackend:currentCry()
  for id in pairs(self.playing) do
    if id:sub(1, 4) == "cry:" then
      return id
    end
  end
  return nil
end

function FakeAudioBackend:playFanfare(fanfare)
  local token = "fanfare:" .. tostring(fanfare)
  self.playing[token] = true
  self.calls[#self.calls + 1] = { op = "playFanfare", fanfare = fanfare }
end

function FakeAudioBackend:currentFanfare()
  for id in pairs(self.playing) do
    if id:sub(1, 8) == "fanfare:" then
      return id
    end
  end
  return nil
end

-- Engine-owned async: sounds stop after their catalog duration.
function FakeAudioBackend:advance()
  for id in pairs(self.playing) do
    self.playing[id] = nil
  end
end

---@class FakeScreenBackend
---@field fading boolean
---@field calls table[]
local FakeScreenBackend = {}
FakeScreenBackend.__index = FakeScreenBackend

function FakeScreenBackend.new()
  return setmetatable({ fading = false, calls = {} }, FakeScreenBackend)
end

function FakeScreenBackend:startFade(spec)
  self.fading = true
  self.calls[#self.calls + 1] = { op = "startFade", spec = spec }
end

function FakeScreenBackend:advance()
  self.fading = false
end

function FakeScreenBackend:fadeDone()
  return not self.fading
end

---@class FakeCameraBackend
---@field calls table[]
local FakeCameraBackend = {}
FakeCameraBackend.__index = FakeCameraBackend

function FakeCameraBackend.new()
  return setmetatable({ calls = {} }, FakeCameraBackend)
end

function FakeCameraBackend:startShake(spec)
  self.calls[#self.calls + 1] = { op = "startShake", spec = spec }
end

---@class FakeMapsBackend
---@field warping boolean
---@field calls table[]
local FakeMapsBackend = {}
FakeMapsBackend.__index = FakeMapsBackend

function FakeMapsBackend.new()
  return setmetatable({ warping = false, calls = {} }, FakeMapsBackend)
end

function FakeMapsBackend:startWarp(target)
  self.warping = true
  self.calls[#self.calls + 1] = { op = "startWarp", target = target }
end

function FakeMapsBackend:advance()
  self.warping = false
end

function FakeMapsBackend:warpDone()
  return not self.warping
end

---@class AwsHarness
---@field services FakeServices
---@field registry Registry
---@field composition Composition
---@field taskRegistry TaskRegistry
---@field scheduler Scheduler
---@field audio FakeAudioBackend|nil
---@field camera FakeCameraBackend|nil
---@field screen FakeScreenBackend|nil
---@field maps FakeMapsBackend|nil

---@param opts table|nil
---@return AwsHarness
local function harness(opts)
  opts = opts or {}
  local services = FakeServices.new(opts)
  local audio = opts.audio and FakeAudioBackend.new() or nil
  local camera = opts.camera and FakeCameraBackend.new() or nil
  local screen = opts.screen and FakeScreenBackend.new() or nil
  local maps = opts.maps and FakeMapsBackend.new() or nil
  services.audio = audio
  services.camera = camera
  services.screen = screen
  services.maps = maps
  services.advanceAsync = function()
    if audio then
      audio:advance()
    end
    if screen then
      screen:advance()
    end
    if maps then
      maps:advance()
    end
  end
  local registry = Registry.new()
  local composition = Composition.new(registry)
  local taskRegistry = TaskRegistry.new()
  taskRegistry:register("wait_ticks", 1, WaitTicksTask)
  taskRegistry:register("sound_wait", 1, SoundWaitTask)
  taskRegistry:register("fade", 1, FadeTask)
  taskRegistry:register("warp", 1, WarpTask)
  local scheduler = Scheduler.new({
    services = services,
    taskRegistry = taskRegistry,
    resolveComposition = function(id)
      return composition:effective(id)
    end,
  })
  return {
    services = services,
    registry = registry,
    composition = composition,
    taskRegistry = taskRegistry,
    scheduler = scheduler,
    audio = audio,
    camera = camera,
    screen = screen,
    maps = maps,
  }
end

---@param h AwsHarness
---@param resource table
---@param tick integer
---@return string instanceId
local function startForeground(h, resource, tick)
  if h.registry:base(resource.id) == nil then
    h.registry:installBase(resource.id, resource, "generated")
  end
  local composed = assert(h.composition:effective(resource.id))
  return h.scheduler:createForeground(composed, nil, tick)
end

local function script(id, steps)
  return S.script({ api = 1, id = id, steps = steps })
end

-- 1. Sound wait with a completing backend: PlaySE at T, the wait completes
-- when the backend reports the effect finished, continuation one tick later.
T["sound wait backend completion"] = function()
  local h = harness({ audio = true })
  local resource = script("test.se", {
    S.playSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.waitSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.audio.calls[1].op, "play")
  Assert.equal(h.audio.calls[1].id, "SEQ_SE_DP_SELECT")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  -- The engine-owned async phase ends the effect before 101's poll, which
  -- completes the wait; the successful poll must not continue the graph in
  -- its own tick.
  h.scheduler:step(101, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0, "the successful poll must not continue the graph same tick")
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 2. A wait whose backend cannot report completion faults instead of
-- inventing a simulated duration; a cry wait carries its own token.
T["sound wait without backend faults"] = function()
  local h = harness({ audio = false })
  local resource = script("test.sefault", {
    S.waitSound({ sound = "SEQ_SE_DP_SELECT" }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  local instanceId = startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.scheduler:instance(instanceId)).endReason, "SCRIPT_SERVICE_MISSING")
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
end

T["cry wait uses its named token"] = function()
  local h = harness({ audio = true })
  local resource = script("test.cry", {
    S.playCry({ species = "SPECIES_CYNDAQUIL", form = 0 }),
    S.waitCry(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  Assert.notNil(h.audio:currentCry(), "the cry plays under its own token")
  -- The engine-owned async phase ends the cry before the next tick's poll.
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 3. Fade: fade_screen starts the fade same-tick; wait_fade blocks until the
-- screen backend reports completion.
T["fade and wait fade"] = function()
  local h = harness({ screen = true })
  local resource = script("test.fade", {
    S.fadeScreen({ kind = 6, speed = 1, direction = "out", color = "black" }),
    S.waitFade(),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.screen.calls[1].op, "startFade")
  Assert.equal(h.screen.calls[1].spec.kind, 6)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 0)
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 4. Warp: the warp task starts the transition through the maps service and
-- completes when the transition finishes; continuation follows the handoff.
T["warp task"] = function()
  local h = harness({ maps = true })
  local resource = script("test.warp", {
    S.warp({
      map = "MAP_NEW_BARK",
      warp = 0,
      fieldX = 684,
      fieldZ = 393,
      facing = "south",
    }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  local target = h.maps.calls[1].target
  Assert.equal(target.map, "MAP_NEW_BARK")
  Assert.equal(target.fieldX, 684)
  Assert.equal(target.facing, "south")
  h.scheduler:step(101, nil)
  h.scheduler:step(102, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
end

-- 4b. The real maps service drives a scripted warp through a colon-method
-- loader: the destination coordinates are rebased by the destination map's
-- origin, and a loader that raises for an unknown map is a re-raised fault
-- (never a silent "not found").
T["real maps service warp"] = function()
  local ScriptMapsService = require("libs.engine.src.script.ScriptMapsService")
  local Errors = require("libs.rom.src.Errors")
  local started = nil
  local loader = {}
  loader.load = function(self, symbol)
    assert(self == loader, "load is a colon method")
    if symbol == "MAP_NEW_BARK" then
      return { mapId = 60, coordinateOrigin = { x = 680, z = 390 } }
    end
    Errors.raise("FIELD_MAP_UNKNOWN", "no runtime map for " .. tostring(symbol), {})
  end
  local transition = {
    start = function(self, sourceMap, warp, facing)
      started = { warp = warp, facing = facing }
    end,
  }
  local maps = ScriptMapsService.new({
    transition = transition,
    loader = loader,
    sourceMap = { mapId = 57 },
  })
  maps:startWarp({ map = "MAP_NEW_BARK", warp = 0, fieldX = 4, fieldZ = 3, facing = "north" })
  started = started --[[@as { warp: { destinationMapId: integer, x: integer, z: integer }, facing: string }]]
  Assert.equal(started.warp.destinationMapId, 60)
  Assert.equal(started.warp.x, 684, "destination-local x rebased by the map origin")
  Assert.equal(started.warp.z, 393)
  Assert.equal(started.facing, "north")
  Assert.isNil(maps:resolve("MAP_MISSING"))
  local maps2 = ScriptMapsService.new({
    transition = transition,
    loader = loader,
    sourceMap = { mapId = 57 },
  })
  local ok, err = pcall(maps2.startWarp, maps2, { map = "MAP_MISSING" })
  Assert.isFalse(ok)
  ---@cast err Errors.Error
  Assert.isTrue(
    Errors.is(err) and err.code == "FIELD_MAP_UNKNOWN",
    "a loader fault re-raises instead of becoming a missing map"
  )
end

-- 5. Music and camera operations are same-tick passthroughs.
T["music and camera same tick"] = function()
  local h = harness({ audio = true, camera = true })
  local resource = script("test.music", {
    S.playMusic({ music = "SEQ_GS_NEW_BARK" }),
    S.stopMusic({ music = "SEQ_GS_NEW_BARK" }),
    S.temporaryMusic({ music = "SEQ_GS_EVENT" }),
    S.resetMusic(),
    S.fadeMusicOut({ durationTicks = 30 }),
    S.fadeMusicIn({ durationTicks = 30 }),
    S.shakeCamera({ amplitudeX = 2, amplitudeY = 0, intervalTicks = 2, count = 8 }),
    S.setVar({ variable = "VAR_AFTER", value = 1 }),
    S.stop(),
  })
  startForeground(h, resource, 100)
  h.scheduler:step(100, nil)
  Assert.equal(h.services.world:getVar("VAR_AFTER"), 1)
  local ops = {}
  for _, call in ipairs(h.audio.calls) do
    ops[#ops + 1] = call.op
  end
  Assert.deepEqual(ops, { "playMusic", "stopMusic", "temporaryMusic", "resetMusic", "fadeMusicOut", "fadeMusicIn" })
  Assert.equal(h.camera.calls[1].op, "startShake")
  Assert.equal(h.camera.calls[1].spec.count, 8)
end

-- 6. A warp from a background script is forbidden .
T["background cannot warp"] = function()
  local h = harness({ maps = true })
  local resource = script("test.bgwarp", {
    S.warp({ map = "MAP_NEW_BARK", warp = 0, fieldX = 1, fieldZ = 1, facing = "north" }),
    S.stop(),
  })
  h.registry:installBase(resource.id, resource, "generated")
  local composed = assert(h.composition:effective(resource.id))
  local instanceId = h.scheduler:createBackground(composed, nil, 100)
  h.scheduler:step(100, nil)
  Assert.equal(assert(h.scheduler:instance(instanceId)).endReason, "SCRIPT_BACKGROUND_FORBIDDEN")
end

return T
