-- TerrainMaterialAnimator: the terrain playback state for one map runtime --
-- the shared per-name texture-swap clocks (the field manager's per-tick
-- counter state machine over the compiled fldtanime schedule) and the
-- looping area texture-SRT playback (the compiled NSBTA clip), composed
-- over { record, runtime } bindings the loaders build from the generated
-- scene-form material records and the runtime material tables the draw
-- items reference.
--
-- Each texture-swap animation name owns one clock over its replacement
-- steps: construction puts the clock on step 1 with 0 ticks elapsed and
-- leaves every runtime material on its initial image (the loader bound the
-- base material.texture), acquiring every replacement step image up front
-- through the injected resolver. Each updateFixed counts one tick; when the
-- current step's durationTicks expires the clock advances (wrapping at the
-- step list end) and only then swaps every member of the group to the new
-- step's own preloaded image. Same-name materials share one clock and stay
-- in phase, each selecting from its own preloaded array -- neighbor cells
-- compile against their own packs, so same-name arrays may hold different
-- paths; the asset cache validates that same-name schedules agree.
--
-- The texture-SRT clip plays through one looping AnimationPlayer: frame 0
-- is sampled at construction, and updateFixed advances one frame and
-- re-samples every targeted material through TextureSrtEvaluator (the
-- shared composition with MaterialEvaluator); untargeted materials keep the
-- matrix construction initialized. Construction initializes every binding's
-- texMatrix -- the static srt, or the frame-0 NSBTA sample for a clip
-- target -- so a fully static scene needs no separate path. updateFixed
-- performs no acquisition, filesystem access, descriptor mutation, or
-- draw-list rebuild. The animator owns only Lua playback/counter state --
-- the image pool owns every Image and remains the sole release owner.
-- Records and the clip are read-only. Pure domain module.
local AnimationPlayer = require("libs.engine.src.AnimationPlayer")
local CompiledNsbtaSampler = require("libs.engine.src.CompiledNsbtaSampler")
local TextureSrtEvaluator = require("libs.engine.src.TextureSrtEvaluator")

---@class TerrainMaterialAnimator
---@field groups { steps: table, stepIndex: integer, ticksInStep: integer, members: table[] }[]
---@field targeted { record: table, runtime: table, targetIndex: integer }[]
---@field clip table|false
---@field player table|nil
local TerrainMaterialAnimator = {}
TerrainMaterialAnimator.__index = TerrainMaterialAnimator

-- Build the playback state over the loaders' bindings. The asset cache owns
-- generated-data validation (including the same-name schedule agreement the
-- shared clocks rely on); only true local programming faults are asserted
-- here. `clip` is the compiled texsrt clip or false for no area animation.
---@param bindings { record: table, runtime: table }[] scene material record + live runtime material table
---@param clip table|false the compiled texsrt clip or false for no area animation
---@param resolveImage fun(path: string, wrapX: string, wrapY: string): any the pool-backed image resolver
---@return TerrainMaterialAnimator
function TerrainMaterialAnimator.new(bindings, clip, resolveImage)
  assert(type(bindings) == "table", "TerrainMaterialAnimator.new requires the bindings")
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

  for _, binding in ipairs(bindings) do
    local record = assert(binding.record, "TerrainMaterialAnimator.new requires bindings with records")
    local runtime = assert(binding.runtime, "TerrainMaterialAnimator.new requires bindings with runtime materials")

    local swap = record.textureSwap
    if swap then
      assert(type(swap.name) == "string" and swap.name ~= "", "a texture-swap material has an empty animation name")
      assert(
        type(swap.steps) == "table" and #swap.steps > 0,
        "animation " .. tostring(swap.name) .. " has no playback steps"
      )
      assert(
        type(record.wrap) == "table" and type(record.wrap.x) == "string" and type(record.wrap.y) == "string",
        "texture-swap material " .. tostring(record.name) .. " has no wrap state for its frame acquisition"
      )
      local group = groupByName[swap.name]
      if not group then
        group = {
          name = swap.name,
          steps = swap.steps,
          stepIndex = 1,
          ticksInStep = 0,
          members = {},
        }
        groups[#groups + 1] = group
        groupByName[swap.name] = group
      end

      local images = {}
      for stepIndex, step in ipairs(swap.steps) do
        assert(
          type(step.texture) == "string",
          "animation " .. tostring(swap.name) .. " carries a non-string step texture"
        )
        images[stepIndex] = resolveImage(step.texture, record.wrap.x, record.wrap.y)
      end
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
-- counter step, and when the current step's duration crosses, the clock
-- advances (wrapping at the step list end) and every member selects the new
-- step from its own preloaded array; the looping SRT player advances one
-- frame and each targeted material's matrix is re-sampled. Untargeted
-- matrices keep their base value. Image assignment happens only inside the
-- step-crossing branch. No acquisition, filesystem access, or record
-- mutation here.
function TerrainMaterialAnimator:updateFixed()
  for _, group in ipairs(self.groups) do
    local step = group.steps[group.stepIndex]
    if step.durationTicks > group.ticksInStep then
      group.ticksInStep = group.ticksInStep + 1
    else
      group.ticksInStep = 1
      group.stepIndex = group.stepIndex % #group.steps + 1
      for _, member in ipairs(group.members) do
        member.runtime.image = member.images[group.stepIndex]
      end
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
