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
-- Door ownership is precomputed once when the scene is assembled: the
-- assembly enumerates the DOOR-kind (behavior 105) tiles of the permission
-- cell (DoorTiles.fromGrid, local indices 0..31) and resolves each to the
-- placement whose pivot (the transform translation, [13]/[15]) is NEAREST
-- the tile centre -- the predicate verified against the real ROM, where
-- door models are planar slabs whose model-space AABB does not contain the
-- tile centre (New Bark member 26: x[-0.3,0.0] z[0.0,0.0]) and a containment
-- test resolves the wrong static building. doorAt is then an O(1) index
-- lookup: no placement scan, no matrix inversion, no epsilon on the hot
-- path. The index is authoritative: a tile it does not cover resolves nil,
-- and mutating the placement list after assembly changes nothing. Ambiguity
-- (two placements tied for one door tile) and missing coverage (a door tile
-- with no placement at all) are data failures diagnosed once at assembly,
-- not per lookup. Only DOOR-kind warp tiles resolve; stairs, directional
-- warps, and generic warps return nil (their choreography is separate
-- policy). A door whose building is static (no animated instance) resolves
-- but animates nothing -- HGSS's interior doors without animation records
-- behave the same. Pure domain module.
--
-- The playback surface is the collapsed animation object graph:
-- MapProps carries no controller. MapDoor plays through the instance and
-- retains the returned play handle on the tile's index entry
-- (entry.animation); isFinished reads that handle, so the finish state never
-- depends on the disposable MapDoor identity. SceneProp keeps exactly
-- play/stop/isFinished -- pause/resume/setDirection/animationsFor have no
-- production caller and do not exist.

local WarpSystem = require("libs.engine.src.WarpSystem")
local TransitionTrigger = require("libs.engine.src.TransitionTrigger")
local FieldGrid = require("libs.engine.src.FieldGrid")
local Errors = require("libs.rom.src.Errors")
local AnimationClip = require("libs.engine.src.AnimationClip")
local ModelAnimationState = require("libs.engine.src.ModelAnimationState")

---@class MapProps
---@field placements table -- scene placement records (read only after assembly)
---@field placementIndex table -- [placementIndex] = { modelKey }
---@field doorIndex table -- ["localX:localZ"] = { placementIndex, modelKey, animation }
---@field instances { [integer]: ModelInstance|nil }
local MapProps = {}
MapProps.__index = MapProps

local function raiseUnknown(definition, animation)
  Errors.raise(
    "MAP_PROP_ANIM_UNKNOWN",
    "map prop has no animation named " .. tostring(animation) .. " (model " .. definition.key .. ")",
    { animation = animation, modelKey = definition.key }
  )
end

-- `doorTiles` are the DOOR-kind tiles of the scene's permission cell as
-- local indices -- exactly the list the assembly enumerates and the space
-- doorAt keys its index with. Ambiguity (two placements tied for one tile)
-- and missing coverage (a door tile with no placement at all) raise here,
-- once, as generated-data failures rather than per-lookup surprises.
---@param opts { placements: table, instances: { [integer]: table|nil }, doorTiles: { x: integer, z: integer }[] }
---@return MapProps
function MapProps.new(opts)
  assert(opts and opts.placements and opts.instances and opts.doorTiles, "map props options required")
  local self = setmetatable({
    placements = opts.placements,
    instances = opts.instances,
    placementIndex = {},
    doorIndex = {},
  }, MapProps)
  for _, placement in ipairs(opts.placements) do
    assert(placement.placementIndex ~= nil, "placement missing placementIndex: " .. tostring(placement.modelKey))
    self.placementIndex[placement.placementIndex] = { modelKey = placement.modelKey }
  end
  for _, tile in ipairs(opts.doorTiles) do
    local wx, wz = FieldGrid.tileCenterToWorld(tile.x, tile.z)
    local best
    for _, placement in ipairs(opts.placements) do
      local dx, dz = placement.transform[13] - wx, placement.transform[15] - wz
      local distance = dx * dx + dz * dz
      if not best then
        best = { placement = placement, distance = distance }
      elseif distance < best.distance then
        best = { placement = placement, distance = distance }
      elseif distance == best.distance then
        Errors.raise(
          "MAP_PROP_AMBIGUOUS_DOOR",
          "door tile ("
            .. tile.x
            .. ","
            .. tile.z
            .. ") is tied between placements "
            .. best.placement.placementIndex
            .. " and "
            .. placement.placementIndex,
          {
            x = tile.x,
            z = tile.z,
            placements = { best.placement.placementIndex, placement.placementIndex },
          }
        )
      end
    end
    if not best then
      Errors.raise(
        "MAP_PROP_UNCOVERED_DOOR",
        "door tile (" .. tile.x .. "," .. tile.z .. ") has no building placement",
        { x = tile.x, z = tile.z }
      )
    end
    self.doorIndex[tile.x .. ":" .. tile.z] = {
      placementIndex = best.placement.placementIndex,
      modelKey = best.placement.modelKey,
      animation = nil,
    }
  end
  return self
end

-- The MapDoor handle: the resolved door at a tile. `instance` is the door's
-- building ModelInstance (nil for static buildings) and `entry` is the
-- tile's retained index record -- the play handle lives there, not on the
-- disposable handle, so a fresh resolution of the tile observes the
-- animation the previous handle played.
---@class MapDoor
---@field x integer
---@field z integer
---@field warp table -- the warp record at the door tile
---@field placementIndex integer
---@field modelKey string
---@field instance table|nil
---@field entry table -- the retained index record ({ animation = handle|nil })
local MapDoor = {}
MapDoor.__index = MapDoor

-- Play the door's opening animation: the semantic door.open role, once, from
-- frame 0, stopping the door's previous play. A static door (no animated
-- instance) has nothing to play and does nothing, like HGSS doors without
-- animation records. Raises MAP_PROP_ANIM_UNKNOWN when the model's clips
-- lack the role (a data problem worth a diagnostic, not a silent fallback).
function MapDoor:open()
  self:_play(AnimationClip.ROLES.DOOR_OPEN)
end

-- Play the door's closing animation: the semantic door.close role, once,
-- from frame 0, stopping the door's previous play. Static doors no-op.
function MapDoor:close()
  self:_play(AnimationClip.ROLES.DOOR_CLOSE)
end

-- One door has one playing attachment: playing a role stops the tile's
-- retained play handle first, then plays fresh from frame 0. The retained
-- handle is the LIVE attachment instance:play returned, so isFinished reads
-- it directly and replays always restart.
function MapDoor:_play(role)
  if not self.instance then
    return
  end
  local definition = self.instance.definition
  if not definition:animation(role) then
    raiseUnknown(definition, role)
  end
  if self.entry.animation then
    self.instance:stop(self.entry.animation)
  end
  self.entry.animation = self.instance:play(role, { loopMode = "once" })
end

-- Whether the door's current animation has reached its end (the player's
-- single checked-advance completion: a once-clip finishes exactly when its
-- frame reaches numFrame * FRAME_UNIT). Nil when nothing is playing -- a
-- static door, or a door that has not been opened or closed yet -- so a
-- waiter treats nil as "nothing to wait for". The handle is read from the
-- tile's retained index record, so any handle resolving this tile reports
-- the same finish state.
function MapDoor:isFinished()
  if not self.instance or not self.entry.animation then
    return nil
  end
  return self.entry.animation.player:isComplete()
end

-- Resolve the door at a field tile: the tile must carry a warp whose
-- metatile behavior classifies as a DOOR (behavior 105). Returns a MapDoor
-- for the tile's precomputed placement -- the O(1) index read over the
-- scene's local door tiles; the nearest pivot, ambiguity, and missing
-- coverage were decided once at assembly -- or nil when the tile is out of
-- permission coverage, has no warp, is not a door-kind warp, or the index
-- does not cover it. `instance` is read live from the current instance
-- table, so a door whose model loses its animated instance after assembly
-- resolves statically.
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
  local entry = self.doorIndex[localX .. ":" .. localZ]
  if not entry then
    return nil
  end
  return setmetatable({
    x = fieldX,
    z = fieldZ,
    warp = warp,
    placementIndex = entry.placementIndex,
    modelKey = entry.modelKey,
    instance = self.instances[entry.placementIndex],
    entry = entry,
  }, MapDoor)
end

-- The generic scripted-prop handle: an animated placement addressed by its
-- map-data index, with the semantic playback surface scripts use. Unlike the
-- door lookup it needs no tile or behavior classification -- scripts know
-- the object they animate (HGSS addresses field objects by index). A static
-- placement (no animated instance) resolves to a handle whose ops no-op.
-- The surface is exactly play/stop/isFinished; pause/resume/setDirection/
-- animationsFor have no production caller and do not exist.
---@class SceneProp
---@field placementIndex integer
---@field modelKey string
---@field instance table|nil
---@field pause nil -- deliberately absent: no production caller
---@field resume nil
---@field setDirection nil
---@field animationsFor nil
local SceneProp = {}
SceneProp.__index = SceneProp

-- The playing attachment of a prop's clip, or nil when nothing plays.
local function attachmentByClip(instance, clip)
  for _, category in ipairs(ModelAnimationState.GROUPS) do
    for _, attachment in ipairs(instance.animationState:attachments(category)) do
      if attachment.clip == clip then
        return attachment
      end
    end
  end
  return nil
end

-- Play an animation by role or clip name; `opts` passes through to the
-- instance (priority, ratioFx, loopMode, direction). Returns the live
-- attachment handle. Raises MAP_PROP_ANIM_UNKNOWN for a name the model does
-- not define.
function SceneProp:play(animation, opts)
  if not self.instance then
    return nil
  end
  if not self.instance.definition:animation(animation) then
    raiseUnknown(self.instance.definition, animation)
  end
  return self.instance:play(animation, opts)
end

-- Stop an animation by role or clip name.
function SceneProp:stop(animation)
  if not self.instance then
    return nil
  end
  if not self.instance.definition:animation(animation) then
    raiseUnknown(self.instance.definition, animation)
  end
  return self.instance:stop(animation)
end

-- The player's single checked-advance completion for the prop's play of
-- `animation` (a once-clip finishes exactly when its frame reaches numFrame *
-- FRAME_UNIT), or nil when nothing is playing (a static prop, or no play
-- yet) -- a waiter treats nil as "nothing to wait for".
function SceneProp:isFinished(animation)
  if not self.instance then
    return nil
  end
  local clip = self.instance.definition:animation(animation)
  if not clip then
    raiseUnknown(self.instance.definition, animation)
  end
  local attachment = attachmentByClip(self.instance, clip)
  if not attachment then
    return nil
  end
  return attachment.player:isComplete()
end

-- Resolve the scripted-prop handle for a placement index, or nil when no
-- placement has that index. The placement index is precomputed at assembly
-- like the door index: prop() never rescans the placement list per call.
---@param placementIndex integer
---@return SceneProp?
function MapProps:prop(placementIndex)
  local entry = self.placementIndex[placementIndex]
  if not entry then
    return nil
  end
  return setmetatable({
    placementIndex = placementIndex,
    modelKey = entry.modelKey,
    instance = self.instances[placementIndex],
  }, SceneProp)
end

return MapProps
