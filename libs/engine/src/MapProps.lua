-- MapProps: the door/model lookup facade. A scene's map props resolve a
-- field coordinate to the door of the building placed there -- field
-- coordinate -> building placement -> ModelInstance -> semantic door
-- animation -- with the doorway API gameplay uses:
--
--     door = mapProps:doorAt(runtimeMap, x, z)
--     door:open()
--     door:close()
--     door:isFinished()
--
-- Nothing here knows NARC ids, animation resource numbers, NSBCA, or
-- animation-list slots: the resolution is spatial (the placement nearest the
-- door tile centre), the animation is the placement instance's semantic
-- door.open/door.close roles through the MapPropAnimationController, and a
-- door whose building is static (no animated instance) resolves but animates
-- nothing -- HGSS's interior doors without animation records behave the same.
-- Only DOOR-kind warp tiles (behavior 105) resolve; stairs, directional
-- warps, and generic warps return nil (their choreography is separate policy).
-- Pure domain module.

local WarpSystem = require("libs.engine.src.WarpSystem")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")
local FieldGrid = require("libs.engine.src.FieldGrid")

---@class MapProps
---@field placements table -- scene.buildingInstances records
---@field instances { [integer]: ModelInstance|nil }
---@field controller table -- MapPropAnimationController
local MapProps = {}
MapProps.__index = MapProps

---@param opts { placements: table, instances: { [integer]: table|nil }, controller: table }
---@return MapProps
function MapProps.new(opts)
  assert(opts and opts.placements and opts.instances and opts.controller, "map props options required")
  return setmetatable({
    placements = opts.placements,
    instances = opts.instances,
    controller = opts.controller,
  }, MapProps)
end

-- The MapDoor handle: the resolved door at a tile. `instance` is the door's
-- building ModelInstance (nil for static buildings), `controller` drives its
-- semantic playback.
---@class MapDoor
---@field x integer
---@field z integer
---@field warp table -- the warp record at the door tile
---@field placementIndex integer
---@field modelKey string
---@field instance table|nil
---@field currentRole "door.open"|"door.close"|nil
---@field controller table -- the MapPropAnimationController
local MapDoor = {}
MapDoor.__index = MapDoor

-- Play the door's opening animation: the semantic door.open role, once, from
-- frame 0, stopping any door.close in progress. A static door (no animated
-- instance) has nothing to play and does nothing, like HGSS doors without
-- animation records. Raises MAP_PROP_ANIM_UNKNOWN when the model's clips
-- lack the role (a data problem worth a diagnostic, not a silent fallback).
function MapDoor:open()
  self:_play("door.open")
end

-- Play the door's closing animation: the semantic door.close role, once,
-- from frame 0, stopping any door.open in progress. Static doors no-op.
function MapDoor:close()
  self:_play("door.close")
end

function MapDoor:_play(role)
  if not self.instance then
    return
  end
  local definition = self.instance.definition
  local other = role == "door.open" and "door.close" or "door.open"
  if definition:animation(other) then
    self.controller:stop(self.instance, other)
  end
  self.controller:play(self.instance, role, { loopMode = "once" })
  self.currentRole = role
end

-- Whether the door's current animation has reached its end (the controller's
-- HGSS checked-advance completion). Nil when nothing is playing -- a static
-- door, or a door that has not been opened or closed yet -- so a waiter
-- treats nil as "nothing to wait for".
function MapDoor:isFinished()
  if not self.instance or not self.currentRole then
    return nil
  end
  return self.controller:isFinished(self.instance, self.currentRole)
end

-- Resolve the door at a field tile: the tile must carry a warp whose
-- metatile behavior classifies as a DOOR (behavior 105). Returns a MapDoor
-- for the building placement nearest the tile's centre, or nil when the tile
-- is out of permission coverage, has no warp, or is not a door-kind warp.
---@param runtimeMap table
---@param fieldX integer
---@param fieldZ integer
---@return MapDoor?
function MapProps:doorAt(runtimeMap, fieldX, fieldZ)
  local origin = runtimeMap.coordinateOrigin
  local localX, localZ = fieldX - origin.x, fieldZ - origin.z
  if not runtimeMap.permissions:containsLocal(localX, localZ) then
    return nil
  end
  local warp = WarpSystem.findAt(runtimeMap, fieldX, fieldZ)
  if not warp then
    return nil
  end
  -- The tile is inside permission coverage (checked above), so the behavior
  -- byte is always present.
  local behavior = assert(TransitionTrigger.behaviorAt(runtimeMap, fieldX, fieldZ))
  local classification = TransitionTrigger.classify(behavior)
  if not classification or classification.kind ~= "door" then
    return nil
  end

  local tileWorldX, tileWorldZ = FieldGrid.tileCenterToWorld(localX, localZ)
  local nearest, nearestDistance
  for _, placement in ipairs(self.placements) do
    local transform = placement.transform
    local dx = transform[13] - tileWorldX
    local dz = transform[15] - tileWorldZ
    local distance = dx * dx + dz * dz
    if not nearest or distance < nearestDistance then
      nearest, nearestDistance = placement, distance
    end
  end
  if not nearest then
    return nil
  end
  return setmetatable({
    x = fieldX,
    z = fieldZ,
    warp = warp,
    placementIndex = nearest.placementIndex,
    modelKey = nearest.modelKey,
    instance = self.instances[nearest.placementIndex],
    controller = self.controller,
    currentRole = nil,
  }, MapDoor)
end

-- The generic scripted-prop handle: an animated placement addressed by its
-- map-data index, with the semantic playback surface scripts use. Unlike the
-- door lookup it needs no tile or behavior classification -- scripts know
-- the object they animate (HGSS addresses field objects by index). A static
-- placement (no animated instance) resolves to a handle whose ops no-op.
---@class SceneProp
---@field placementIndex integer
---@field modelKey string
---@field instance table|nil
---@field controller table -- the MapPropAnimationController
local SceneProp = {}
SceneProp.__index = SceneProp

-- Play an animation by role or clip name; `opts` passes through to the
-- controller (priority, ratioFx, loopMode, repeatsRemaining, deltaFx,
-- direction). Returns the attachment token. Raises MAP_PROP_ANIM_UNKNOWN for
-- a name the model does not define.
function SceneProp:play(animation, opts)
  if not self.instance then
    return nil
  end
  return self.controller:play(self.instance, animation, opts)
end

-- Stop an animation by role or clip name.
function SceneProp:stop(animation)
  if not self.instance then
    return nil
  end
  return self.controller:stop(self.instance, animation)
end

function SceneProp:pause(animation)
  if not self.instance then
    return
  end
  self.controller:pause(self.instance, animation)
end

function SceneProp:resume(animation)
  if not self.instance then
    return
  end
  self.controller:resume(self.instance, animation)
end

function SceneProp:setDirection(animation, direction)
  if not self.instance then
    return
  end
  self.controller:setDirection(self.instance, animation, direction)
end

-- The HGSS checked-advance completion for the controller's play of
-- `animation`, or nil when nothing is playing (a static prop, or no play
-- yet) -- a waiter treats nil as "nothing to wait for".
function SceneProp:isFinished(animation)
  if not self.instance then
    return nil
  end
  return self.controller:isFinished(self.instance, animation)
end

-- The playing clips of the prop (the controller's instance view).
function SceneProp:animationsFor()
  if not self.instance then
    return {}
  end
  return self.controller:animationsFor(self.instance)
end

-- Resolve the scripted-prop handle for a placement index, or nil when no
-- placement has that index.
---@param placementIndex integer
---@return SceneProp?
function MapProps:prop(placementIndex)
  for _, placement in ipairs(self.placements) do
    if placement.placementIndex == placementIndex then
      return setmetatable({
        placementIndex = placementIndex,
        modelKey = placement.modelKey,
        instance = self.instances[placementIndex],
        controller = self.controller,
      }, SceneProp)
    end
  end
  return nil
end

return MapProps
