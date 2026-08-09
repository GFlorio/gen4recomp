-- AnimationBinding: the mapping from one clip onto one model. Binding is a
-- loading-time operation -- name/index resolution happens once, never per
-- frame. Joint and visibility clips map node-index targets to model nodes;
-- material clips map material-name targets to model materials:
--
--   binding = AnimationBinding.new(clip, modelKey, {
--       [3]       = 3,        -- joint target node 3 -> model node 3
--       ["door"]  = 1,        -- material target "door" -> model material 1
--   })
--
-- Unmatched clip targets may remain unmapped, matching Nitro's permissive
-- resource binding. A binding whose map resolves zero targets raises a
-- structured diagnostic: that is an importer or association problem, not an
-- intentional asset. The binding never interprets the target key type -- the
-- compiler that built the map owns that semantics. Pure domain module.

local Errors = require("libs.rom.src.Errors")

local AnimationBinding = {}
AnimationBinding.__index = AnimationBinding

-- Build a binding for `clip` over the model identified by `modelKey`.
-- `map` pairs each clip track target with the model element index it binds
-- to (a node index for joint/visibility clips, a material index for material
-- clips). Map keys must be track targets of the clip.
function AnimationBinding.new(clip, modelKey, map)
  assert(type(clip) == "table" and clip.id ~= nil, "AnimationBinding.new requires a clip")
  assert(type(modelKey) == "string" and #modelKey > 0, "modelKey must be a non-empty string")
  assert(type(map) == "table", "binding map must be a table")

  local trackTargets = {}
  for _, track in ipairs(clip.tracks) do trackTargets[track.target] = true end
  for target, index in pairs(map) do
    if not trackTargets[target] then
      Errors.raise("ANIM_BINDING_UNKNOWN_TARGET",
        "clip " .. clip.id .. " has no track targeting " .. tostring(target)
          .. " (binding for " .. modelKey .. ")",
        { target = target, clip = clip.id, modelKey = modelKey })
    end
    if not (type(index) == "number" and math.floor(index) == index and index >= 0) then
      Errors.raise("ANIM_BINDING_BAD_INDEX",
        "binding for clip " .. clip.id .. " maps target " .. tostring(target)
          .. " to a non-integer model index",
        { target = target, clip = clip.id, modelKey = modelKey })
    end
  end

  local mapped = 0
  for _, track in ipairs(clip.tracks) do
    if map[track.target] ~= nil then mapped = mapped + 1 end
  end
  if mapped == 0 then
    Errors.raise("ANIM_BINDING_NO_MAPPED_TARGETS",
      "clip " .. clip.id .. " binds zero targets onto model " .. modelKey
        .. "; the animation/model association is likely wrong",
      { clip = clip.id, modelKey = modelKey })
  end

  return setmetatable({
    clip = clip,
    modelKey = modelKey,
    map = map,
    mappedTargets = mapped,
  }, AnimationBinding)
end

-- The model element index a clip track target binds to, or nil when the
-- target is intentionally unmapped.
function AnimationBinding:modelIndex(target)
  return self.map[target]
end

function AnimationBinding:mappedTargetCount()
  return self.mappedTargets
end

return AnimationBinding
