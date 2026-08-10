-- Production-composed, non-rendering field acceptance harness. It owns an
-- isolated save namespace and a temporary graphics trap around each runtime,
-- while FieldRuntime remains the sole owner of maps, scripts, actors, and saves.

local FieldSave = require("libs.engine.src.FieldSave")
local SaveFs = require("libs.rom.src.SaveFs")
local GameVersion = require("libs.rom.src.GameVersion")
local RomImporter = require("libs.rom.src.RomImporter")
local FieldRuntime = require("game.src.game.FieldRuntime")

---@class AcceptanceHarness
---@field versions string[]
---@field runtimeFactory fun(versionId: string, map: string|integer|nil, runtimeOptions: table|nil): table
---@field saveNamespace fun(versionId: string, serial: integer): string
---@field removeSaveNamespace fun(namespace: string)
local AcceptanceHarness = {}
AcceptanceHarness.__index = AcceptanceHarness

local serial = 0
local TRACE_LIMIT = 32

local function readyVersions()
  local versions = {}
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      versions[#versions + 1] = versionId
    end
  end
  return versions
end

local function defaultNamespace(versionId, index)
  return string.format("acceptance/%s/%d", versionId, index)
end

local function removeNamespace(path)
  local fs = love.filesystem
  fs.remove(path .. "/" .. FieldSave.PATH .. ".tmp")
  fs.remove(path .. "/" .. FieldSave.PATH)
  fs.remove(path)
end

local function installRenderTrap()
  local graphics = love and love.graphics
  if not graphics then
    return { attempts = 0, restore = function() end }
  end
  local trap = { attempts = 0, original = {} }
  for _, name in ipairs({ "newShader", "newCanvas", "newImage", "newMesh", "newQuad", "draw" }) do
    trap.original[name] = graphics[name]
    graphics[name] = function()
      trap.attempts = trap.attempts + 1
      error("acceptance runtime attempted love.graphics." .. name, 2)
    end
  end
  function trap:restore()
    if not self.original then
      return
    end
    for name, value in pairs(self.original) do
      graphics[name] = value
    end
    self.original = nil
  end
  return trap
end

local function abortBoot(runtime, trap, removeSaveNamespace, namespace)
  local disposeErr
  if runtime then
    local ok, err = pcall(function()
      runtime:dispose()
    end)
    if not ok then
      disposeErr = err
    end
  end
  trap:restore()
  removeSaveNamespace(namespace)
  if disposeErr then
    error(disposeErr, 0)
  end
end

local Game = {}
Game.__index = Game

function Game:snapshot()
  local runtime = self.runtime
  local player = runtime.player or {}
  local dialogue = runtime.dialogue
  local scheduler = runtime.scripts and runtime.scripts.scheduler
  return {
    versionId = runtime.versionId,
    mapId = runtime.runtimeMap and runtime.runtimeMap.mapId,
    mapSymbol = runtime.runtimeMap and runtime.runtimeMap.mapSymbol,
    tick = runtime.session and runtime.session.tick,
    player = {
      fieldX = player.fieldX,
      fieldZ = player.fieldZ,
      worldY = player.worldY,
      surfaceId = player.surfaceId,
      facing = player.facing,
      motion = player.motion,
    },
    dialogue = { modal = dialogue and dialogue:isModal() or false },
    fieldLocked = scheduler and scheduler:playerMovementLocked() or false,
    transition = { phase = runtime.transition and runtime.transition.phase },
  }
end

function Game:_record()
  self.timeline[#self.timeline + 1] = self:snapshot()
  if #self.timeline > TRACE_LIMIT then
    table.remove(self.timeline, 1)
  end
end

function Game:trace()
  return self.timeline
end

function Game:step(input)
  if input and input.direction then
    self.runtime:press(input.direction)
  end
  self.runtime:update((self.runtime.session and self.runtime.session.FIXED_DT) or (1 / 30))
  if input and input.direction then
    self.runtime:release(input.direction)
  end
  self:_record()
  return self:snapshot()
end

function Game:move(direction)
  self.runtime:press(direction)
  self:step()
  self.runtime:release(direction)
end

function Game:advanceUntil(label, predicate, maxTicks)
  assert(type(label) == "string" and label ~= "", "advanceUntil label required")
  assert(type(predicate) == "function", "advanceUntil predicate required")
  assert(
    type(maxTicks) == "number" and maxTicks >= 0 and maxTicks < math.huge and maxTicks == math.floor(maxTicks),
    "advanceUntil maxTicks must be a finite non-negative integer"
  )
  for _ = 0, maxTicks do
    local snapshot = self:snapshot()
    if predicate(snapshot) then
      return snapshot
    end
    if _ < maxTicks then
      self:step()
    end
  end
  error(
    "timed out waiting for "
      .. label
      .. "; trace="
      .. tostring(#self.timeline)
      .. " snapshots; last tick="
      .. tostring(self:snapshot().tick),
    2
  )
end

function Game:renderAttempts()
  return self.trap.attempts
end

function Game:close()
  if self.closed then
    return
  end
  if not self.runtimeDisposed then
    self.runtimeDisposed = true
    local ok, err = pcall(function()
      self.runtime:dispose()
    end)
    self.trap:restore()
    if not ok then
      self.disposeErr = err
    end
  end
  self.removeSaveNamespace(self.saveNamespace)
  self.closed = true
  if self.disposeErr then
    error(self.disposeErr, 0)
  end
end

---@param options table|nil
---@return AcceptanceHarness
function AcceptanceHarness.new(options)
  options = options or {}
  return setmetatable({
    versions = options.versions or readyVersions(),
    runtimeFactory = options.runtimeFactory or function(versionId, map, runtimeOptions)
      return FieldRuntime.new(versionId, map, runtimeOptions)
    end,
    saveNamespace = options.saveNamespace or defaultNamespace,
    removeSaveNamespace = options.removeSaveNamespace or removeNamespace,
  }, AcceptanceHarness)
end

function AcceptanceHarness:forEachVersion(fn)
  for _, versionId in ipairs(self.versions) do
    fn(versionId)
  end
end

function AcceptanceHarness:boot(options)
  assert(options and type(options.versionId) == "string", "acceptance boot version required")
  serial = serial + 1
  local namespace = self.saveNamespace(options.versionId, serial)
  local trap = installRenderTrap()
  local ok, runtime = pcall(self.runtimeFactory, options.versionId, options.map, {
    saveFs = SaveFs.forVersion(options.versionId, nil, namespace),
    resumeSave = options.save == "resume",
    resetSave = options.save == "fresh",
  })
  if not ok then
    abortBoot(nil, trap, self.removeSaveNamespace, namespace)
    error(runtime, 0)
  end
  if not runtime or not runtime.session then
    local errorText = runtime and runtime.errorText
    abortBoot(runtime, trap, self.removeSaveNamespace, namespace)
    error("acceptance runtime boot failed: " .. tostring(errorText), 0)
  end
  return setmetatable({
    runtime = runtime,
    saveNamespace = namespace,
    removeSaveNamespace = self.removeSaveNamespace,
    trap = trap,
    timeline = {},
  }, Game)
end

return AcceptanceHarness
