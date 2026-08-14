-- TerrainMaterialAnimator: the terrain playback state for one map runtime --
-- the shared per-name texture-swap clocks (the field manager's per-tick
-- counter state machine over the compiled fldtanime schedule) and the
-- looping area texture-SRT playback (the compiled NSBTA clip), composed
-- over the generated scene-form material records and the runtime material
-- tables the draw items reference.
--
-- Each texture-swap animation name owns one clock: construction puts the
-- cursor on the first live schedule entry with the counter at 0, and each
-- updateFixed tick counts up while that entry's durationTicks exceeds the
-- counter; the crossing resets the counter to 1 and advances the cursor
-- (wrapping at the timeline end). All materials sharing one name stay in
-- phase: on a switch each selects the entry's zero-based texture index from
-- its own preloaded array. Neighbor cells compile against their own packs,
-- so same-name arrays may hold different paths, but they must have equal
-- length and structurally identical timelines -- asserted at construction
-- rather than silently picking one.
--
-- The texture-SRT clip plays through one looping AnimationPlayer: frame 0
-- is sampled at construction, and updateFixed advances one frame and
-- re-samples every targeted material through TextureSrtEvaluator (the
-- shared composition with MaterialEvaluator); untargeted materials keep
-- their base matrix. Construction acquires every swap-frame image through
-- the injected resolver (backed by the loader's image pool) and never
-- advances either clock; updateFixed performs no acquisition, filesystem
-- access, descriptor mutation, or draw-list rebuild. The animator owns only
-- Lua playback/counter state -- the image pool owns every Image and remains
-- the sole release owner. Records and the clip are read-only. Pure domain
-- module.
local AnimationPlayer = require("libs.engine.src.AnimationPlayer")
local CompiledNsbtaSampler = require("libs.engine.src.CompiledNsbtaSampler")
local TextureSrtEvaluator = require("libs.engine.src.TextureSrtEvaluator")

---@class TerrainMaterialAnimator
---@field groups { timeline: table, cursor: integer, counter: integer, members: table[] }[]
---@field targeted { record: table, runtime: table, targetIndex: integer }[]
---@field clip table|false
---@field player table|nil
local TerrainMaterialAnimator = {}
TerrainMaterialAnimator.__index = TerrainMaterialAnimator

-- The shared-clock invariants: every member of one animation group must
-- describe the same schedule entry by entry (no duration collapsing or
-- normalization before the comparison) and hold equally many frames, or the
-- group could not share one cursor.
local function assertSameTimeline(a, b, name)
  assert(
    #a == #b,
    "materials sharing animation name "
      .. tostring(name)
      .. " carry timelines of different lengths ("
      .. tostring(#a)
      .. " vs "
      .. tostring(#b)
      .. ")"
  )
  for i = 1, #a do
    assert(
      a[i].textureIndex == b[i].textureIndex and a[i].durationTicks == b[i].durationTicks,
      "materials sharing animation name " .. tostring(name) .. " carry different schedules at entry " .. tostring(i)
    )
  end
end

---@param records table[] scene-form material records (read-only)
---@param materials { [integer]: { image: any, texMatrix: number[] } } runtime tables keyed by record id
---@param clip table|false the compiled texsrt clip or false for no area animation
---@param resolveImage fun(path: string, wrapX: string, wrapY: string): any the pool-backed image resolver
---@return TerrainMaterialAnimator
function TerrainMaterialAnimator.new(records, materials, clip, resolveImage)
  assert(type(records) == "table", "TerrainMaterialAnimator.new requires the material records")
  assert(type(materials) == "table", "TerrainMaterialAnimator.new requires the runtime material tables")
  assert(
    clip == false or (type(clip) == "table" and type(clip.tracks) == "table" and type(clip.compiled) == "table"),
    "TerrainMaterialAnimator.new requires the compiled texsrt clip or false"
  )
  assert(type(resolveImage) == "function", "TerrainMaterialAnimator.new requires the image resolver")

  local player
  local targetIndexByName
  if clip then
    player = AnimationPlayer.new(clip)
    targetIndexByName = {}
    for _, track in ipairs(clip.tracks) do
      assert(
        type(track.target) == "string" and track.target ~= "",
        "clip " .. tostring(clip.id) .. " has a track without a target name"
      )
      local targetIndex = track.targetIndex
      assert(
        targetIndex ~= nil and targetIndex >= 0 and targetIndex < #clip.compiled.targets,
        "clip "
          .. tostring(clip.id)
          .. " track "
          .. tostring(track.target)
          .. " targets index "
          .. tostring(targetIndex)
          .. " outside the compiled targets"
      )
      assert(
        targetIndexByName[track.target] == nil,
        "clip " .. tostring(clip.id) .. " targets material " .. tostring(track.target) .. " more than once"
      )
      targetIndexByName[track.target] = targetIndex
    end
  end

  local groups = {}
  local groupByName = {}
  local targeted = {}

  for _, record in ipairs(records) do
    assert(type(record) == "table" and record.id ~= nil, "TerrainMaterialAnimator.new requires records with ids")
    local runtime =
      assert(materials[record.id], "no runtime material table for scene material id " .. tostring(record.id))

    local swap = record.textureSwap
    if swap then
      local group = groupByName[swap.name]
      if not group then
        assert(type(swap.name) == "string" and swap.name ~= "", "a texture-swap material has an empty animation name")
        assert(
          type(swap.textures) == "table" and #swap.textures > 0,
          "animation " .. tostring(swap.name) .. " has no texture frames"
        )
        assert(
          type(swap.timeline) == "table" and #swap.timeline > 0,
          "animation " .. tostring(swap.name) .. " has an empty schedule"
        )
        assert(
          type(record.wrap) == "table" and type(record.wrap.x) == "string" and type(record.wrap.y) == "string",
          "texture-swap material " .. tostring(record.name) .. " has no wrap state for its frame acquisition"
        )
        group = {
          timeline = swap.timeline,
          cursor = 1,
          counter = 0,
          members = {},
        }
        groups[#groups + 1] = group
        groupByName[swap.name] = group
      else
        assert(
          #swap.textures == #group.members[1].images,
          "materials sharing animation name "
            .. tostring(swap.name)
            .. " carry differently sized texture arrays ("
            .. tostring(#group.members[1].images)
            .. " vs "
            .. tostring(#swap.textures)
            .. ")"
        )
        assertSameTimeline(swap.timeline, group.timeline, swap.name)
      end

      local frameIndex = swap.timeline[1].textureIndex + 1
      local images = {}
      for index, path in ipairs(swap.textures) do
        assert(type(path) == "string", "animation " .. tostring(swap.name) .. " carries a non-string texture path")
        images[index] = resolveImage(path, record.wrap.x, record.wrap.y)
      end
      runtime.image = images[frameIndex]
      group.members[#group.members + 1] = {
        runtime = runtime,
        images = images,
      }
    end

    local targetIndex = targetIndexByName and targetIndexByName[record.name]
    local sampled
    if targetIndex ~= nil then
      sampled = CompiledNsbtaSampler.sample(clip, targetIndex, player.frameFx)
      targeted[#targeted + 1] = { record = record, runtime = runtime, targetIndex = targetIndex }
    end
    runtime.texMatrix = TextureSrtEvaluator.matrix(record, sampled)
  end

  return setmetatable({
    groups = groups,
    targeted = targeted,
    clip = clip,
    player = player,
  }, TerrainMaterialAnimator)
end

-- Advance every shared clock exactly once: each texture-swap group takes one
-- counter step (the switch lands on the entry's durationTicks crossing) and
-- every member selects the group's current zero-based index from its own
-- preloaded array; the looping SRT player advances one frame and each
-- targeted material's matrix is re-sampled. Untargeted matrices keep their
-- base value. No acquisition, filesystem access, or record mutation here.
function TerrainMaterialAnimator:updateFixed()
  for _, group in ipairs(self.groups) do
    local entry = group.timeline[group.cursor]
    if entry.durationTicks > group.counter then
      group.counter = group.counter + 1
    else
      group.counter = 1
      group.cursor = group.cursor % #group.timeline + 1
    end
    local selected = group.timeline[group.cursor].textureIndex + 1
    for _, member in ipairs(group.members) do
      member.runtime.image = member.images[selected]
    end
  end

  if self.player then
    self.player:updateFixed()
    local frameFx = self.player.frameFx
    for _, entry in ipairs(self.targeted) do
      local sampled = CompiledNsbtaSampler.sample(self.clip, entry.targetIndex, frameFx)
      entry.runtime.texMatrix = TextureSrtEvaluator.matrix(entry.record, sampled)
    end
  end
end

return TerrainMaterialAnimator
