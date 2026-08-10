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
-- animation-list slots: the resolution is spatial (the building whose model
-- footprint -- its model-space AABB under the placement transform -- contains
-- the door tile's world position), the animation is the placement instance's
-- semantic door.open/door.close roles through the MapPropAnimationController,
-- and a door whose building is static (no animated instance) resolves but
-- animates nothing -- HGSS's interior doors without animation records behave
-- the same. The lookup is strict: a door tile contained by no placement
-- resolves nothing, and a tile contained by two placements raises -- a
-- generated map with ambiguous or missing door coverage is a data failure,
-- not an invitation to animate an unrelated building. Only DOOR-kind warp
-- tiles (behavior 105) resolve; stairs, directional warps, and generic warps
-- return nil (their choreography is separate policy). Pure domain module.

local WarpSystem = require("libs.engine.src.WarpSystem")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")
local FieldGrid = require("libs.engine.src.FieldGrid")
local Errors = require("libs.rom.src.Errors")
local Matrix4 = require("libs.math.src.Matrix4")
local MapPropAnimationController = require("libs.engine.src.MapPropAnimationController")

---@class MapProps
---@field placements table -- scene placement records with model-space bounds
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
  self:_play(MapPropAnimationController.ROLES.DOOR_OPEN)
end

-- Play the door's closing animation: the semantic door.close role, once,
-- from frame 0, stopping any door.open in progress. Static doors no-op.
function MapDoor:close()
  self:_play(MapPropAnimationController.ROLES.DOOR_CLOSE)
end

function MapDoor:_play(role)
  if not self.instance then
    return
  end
  local definition = self.instance.definition
  local other = role == MapPropAnimationController.ROLES.DOOR_OPEN and MapPropAnimationController.ROLES.DOOR_CLOSE
    or MapPropAnimationController.ROLES.DOOR_OPEN
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
-- for the placement whose model footprint contains the tile's world centre,
-- or nil when the tile is out of permission coverage, has no warp, is not a
-- door-kind warp, or is contained by no placement. Two placements containing
-- the same tile raise MAP_PROP_AMBIGUOUS_DOOR: on generated data a door tile
-- belongs to exactly one building.
---@param runtimeMap table
---@param fieldX integer
---@param fieldZ integer
---@return MapDoor?
function MapProps:doorAt(runtimeMap, fieldX, fieldZ)
  local origin = runtimeMap.coordinateOrigin
  local localX, localZ = fieldX - origin.x, fieldZ - origin.z
  if not runtimeMap.collision:containsLocal(localX, localZ) then
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
  local contained = {}
  for _, placement in ipairs(self.placements) do
    local bounds = placement.bounds
    if bounds then
      -- Footprint test in model space: the placement transform maps model
      -- space to world, so the tile's world centre maps back into the model
      -- AABB exactly when it lies on the building's footprint.
      local inverse = Matrix4.invert(placement.transform)
      local mx, _, mz = Matrix4.transformPoint(inverse, tileWorldX, 0, tileWorldZ)
      local epsilon = 1e-3
      if
        mx >= bounds.minX - epsilon
        and mx <= bounds.maxX + epsilon
        and mz >= bounds.minZ - epsilon
        and mz <= bounds.maxZ + epsilon
      then
        contained[#contained + 1] = placement
      end
    end
  end
  if #contained == 0 then
    return nil
  end
  if #contained > 1 then
    Errors.raise(
      "MAP_PROP_AMBIGUOUS_DOOR",
      "door tile ("
        .. fieldX
        .. ","
        .. fieldZ
        .. ") on map "
        .. tostring(runtimeMap.mapId)
        .. " is contained by "
        .. #contained
        .. " building placements",
      { mapId = runtimeMap.mapId, x = fieldX, z = fieldZ, placements = #contained }
    )
  end
  local nearest = contained[1]
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
-- controller (priority, ratioFx, loopMode, direction). Returns the
-- attachment token. Raises MAP_PROP_ANIM_UNKNOWN for a name the model does
-- not define.
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
