-- Script maps service : the warp adapter between the
-- script runtime's `maps` service and the field transition subsystem. A
-- script warp targets a map symbol plus destination-local coordinates; the
-- service loads the destination map, converts the coordinates to the global
-- field space the transition expects, synthesizes a direct warp record, and
-- starts the transition. Completion is observed through the transition
-- returning to idle after the application consumed the finished swap, so the
-- warp task's poll cadence stays deterministic. Pure domain module: no love
-- dependency.

local Errors = require("libs.rom.src.Errors")
local ScriptErrors = require("libs.engine.src.script.errors")
local FieldCoordinates = require("libs.engine.src.FieldCoordinates")
local SurfaceResolver = require("libs.engine.src.SurfaceResolver")

---@class ScriptMapsService
---@field private _transition table FieldTransition-shaped
---@field private _loader table FieldMapLoader-shaped
---@field private _sourceMap table RuntimeFieldMap
---@field private _pending table|nil
---@field private _error any|nil
local ScriptMapsService = {}
ScriptMapsService.__index = ScriptMapsService

---@param opts table { transition, loader, sourceMap }
---@return ScriptMapsService
function ScriptMapsService.new(opts)
  assert(
    type(opts) == "table" and opts.transition and opts.loader and opts.sourceMap,
    "script maps service requires a transition, loader, and source map"
  )
  return setmetatable({
    _transition = opts.transition,
    _loader = opts.loader,
    _sourceMap = opts.sourceMap,
    _pending = nil,
    _error = nil,
  }, ScriptMapsService)
end

function ScriptMapsService:currentId()
  return self._sourceMap.mapId
end

-- Rebind the source map after a map swap (the transition replaced it).
---@param sourceMap table RuntimeFieldMap
function ScriptMapsService:setSourceMap(sourceMap)
  self._sourceMap = sourceMap
end

-- Resolve a map symbol to its runtime map; nil only for the known
-- not-found case (FIELD_MAP_UNKNOWN). Any other loader failure is an
-- internal fault and re-raises with attribution.
---@param ref any
---@return table|nil
function ScriptMapsService:resolve(ref)
  if type(ref) ~= "string" then
    return nil
  end
  local ok, map = pcall(self._loader.load, self._loader, ref)
  if ok then
    if map ~= nil and map.mapId ~= nil then
      return map
    end
    return nil
  end
  if Errors.is(map) then
    local err = map --[[@as Errors.Error]]
    if err.code == "FIELD_MAP_UNKNOWN" then
      return nil
    end
    Errors.raise(err.code, err.message, err.context)
  end
  error(map, 0)
end

function ScriptMapsService:has(ref)
  return self:resolve(ref) ~= nil
end

-- Record the player's spawn point for field re-entry. The spawn id is
-- observable through `spawn()`; the field layer consumes it when it rebuilds
-- the player after leaving a scripted map.
---@param spawn string
function ScriptMapsService:setSpawn(spawn)
  self._spawn = spawn
end

-- The recorded spawn point, or nil before any `set_spawn` ran.
---@return string|nil
function ScriptMapsService:spawn()
  return self._spawn
end

-- Start a scripted warp. `target` is the graph node's warp descriptor:
-- { map = "<symbol>", warp = index, fieldX, fieldZ, facing } with the
-- destination coordinates in the destination map's local cell space.
---@param target table
function ScriptMapsService:startWarp(target)
  assert(self._pending == nil, "a scripted warp is already in progress")
  local destination, loadErr = self._loader:load(target.map)
  if destination == nil or destination.mapId == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "warp target map is unavailable: "
        .. tostring(target.map)
        .. (loadErr and (" (" .. tostring(loadErr) .. ")") or ""),
      { map = target.map }
    )
  end
  destination = destination --[[@as table]]
  local origin = destination.coordinateOrigin --[[@as { x: integer, z: integer }]]
  if origin == nil or origin.x == nil or origin.z == nil then
    Errors.raise(
      ScriptErrors.SCRIPT_INVALID_REFERENCE,
      "warp destination has no coordinate origin: " .. tostring(target.map),
      { map = target.map }
    )
  end
  origin = origin --[[@as { x: integer, z: integer }]]
  local warpId = target.warp or 0
  local warp = {
    index = warpId,
    x = origin.x + target.fieldX,
    z = origin.z + target.fieldZ,
    destinationMapId = destination.mapId,
    destinationWarpId = warpId,
    direct = true,
  }
  self._pending = warp
  self._error = nil
  self._transition:start(self._sourceMap, warp, target.facing)
end

-- True when the started warp has run its course: the application consumed
-- the finished swap and the transition returned to idle (or faulted). A
-- transition failure is captured so the warp task can fault its script.
---@return boolean
function ScriptMapsService:warpDone()
  if self._pending == nil then
    return false
  end
  local transition = self._transition
  if transition.error ~= nil then
    self._error = transition.error
    self._pending = nil
    return true
  end
  if transition.phase == "idle" and transition.sourceMap == nil then
    self._pending = nil
    return true
  end
  return false
end

-- The captured failure of the pending warp, or nil on success. The warp task
-- converts it into a faulted task result.
---@return any|nil
function ScriptMapsService:pendingError()
  return self._error
end

return ScriptMapsService
