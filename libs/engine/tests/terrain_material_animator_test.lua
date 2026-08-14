-- TerrainMaterialAnimator tests: the terrain texture-swap clock (the field
-- manager's per-tick counter state machine over the compiled fldtanime
-- schedule) and the looping area texture-SRT playback (the compiled NSBTA
-- clip), composed over { record, runtime } bindings the loaders build from
-- the scene-form material records and the runtime material tables the draw
-- items reference. Construction must leave the runtime material on its
-- initial image (the loader bound the base material.texture), acquire every
-- replacement image once, initialize every binding's texMatrix (static srt
-- or the clip's frame-0 sample), and never mutate the generated descriptor
-- records; updateFixed must advance each shared clock exactly once, assign
-- images only when a schedule boundary crosses, and perform no acquisition.
-- Pure domain; no rendering, no love.

local Assert = require("tests.support.Assert")
local TerrainMaterialAnimator = require("libs.engine.src.TerrainMaterialAnimator")
local TextureSrtEvaluator = require("libs.engine.src.TextureSrtEvaluator")

local T = {}

-- ---- fixture helpers ----

-- A compiled texsrt clip in the NsbtaClipCompiler payload shape: one target
-- with a translation-S curve (the Maya convention's scroll channel) and
-- identity scale/rotation constants.
local function scrollClip(frames, transKeys)
  return {
    id = "fixture:scroll",
    name = "scroll",
    category = "material",
    kind = "texsrt",
    frameCount = frames,
    tracks = { { target = "water", targetIndex = 0 } },
    semanticNames = {},
    compiled = {
      targets = {
        {
          index = 0,
          name = "water",
          channels = {
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
            rot = { source = "constant", value = 0x10000000 },
            transS = { source = "curve", rate = 1, limit = frames, storage = "fx32", keys = transKeys },
            transT = { source = "constant", value = 0 },
          },
        },
      },
    },
  }
end

-- The new-bark-like replacement schedule: R0 for 18 ticks, R1 for 18, R0
-- for 18, R2 for 18, loop (a four-step cycle of 72 ticks).
local function flowerSteps()
  return {
    { texture = "r0.png", durationTicks = 18 },
    { texture = "r1.png", durationTicks = 18 },
    { texture = "r0.png", durationTicks = 18 },
    { texture = "r2.png", durationTicks = 18 },
  }
end

-- A scene-form terrain material with a texture-swap descriptor. The initial
-- image `baseTexture` is the map texture pack's bound image and is NOT part
-- of the replacement schedule.
local function swapRecord(id, name, baseTexture, steps)
  return {
    id = id,
    name = name,
    texture = baseTexture,
    wrap = { x = "repeat", y = "repeat" },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
    textureSwap = {
      name = name,
      steps = steps,
    },
  }
end

-- A scene-form terrain material without a texture swap: optional static srt,
-- optional explicit zero dimensions for the untextured convention.
local function staticRecord(id, name, opts)
  opts = opts or {}
  return {
    id = id,
    name = name,
    texture = opts.texture,
    wrap = { x = "repeat", y = "repeat" },
    texWidth = opts.texWidth or 16,
    texHeight = opts.texHeight or 16,
    texMtxMode = opts.texMtxMode or 0,
    srt = opts.srt,
  }
end

-- A resolver backed by nothing GPU-side: returns a plain preloaded-image
-- table carrying the wrap tag, memoized per path+wrap so identity assertions
-- hold (the pool dedups the same way); records every call. Returns the
-- resolver, the call log, and the image memo.
local function fakeImageResolver()
  local calls = {}
  local images = {}
  local function resolve(path, wrapX, wrapY)
    calls[#calls + 1] = { path = path, wrapX = wrapX, wrapY = wrapY }
    local key = path .. "@" .. wrapX .. "|" .. wrapY
    local image = images[key]
    if not image then
      image = { path = path, wrapTag = wrapX .. "|" .. wrapY }
      images[key] = image
    end
    return image
  end
  return resolve, calls, images
end

-- The loader-side emulation: one runtime material table per record with the
-- base image already bound (the loader's pool resolved material.texture).
-- Returns the binding list.
local function bindings(records, resolve)
  local out = {}
  for _, record in ipairs(records) do
    out[#out + 1] = {
      record = record,
      runtime = {
        id = record.id,
        name = record.name,
        image = record.texture and resolve(record.texture, record.wrap.x, record.wrap.y) or nil,
        texMatrix = nil,
      },
    }
  end
  return out
end

local function assertResolved(calls, path, wrapX, wrapY)
  for _, call in ipairs(calls) do
    if call.path == path and call.wrapX == wrapX and call.wrapY == wrapY then
      return
    end
  end
  Assert.isTrue(
    false,
    "resolver was never called with " .. tostring(path) .. " under " .. tostring(wrapX) .. "/" .. tostring(wrapY)
  )
end

local function assertMatrixEqual(actual, expected, label)
  for i = 1, 9 do
    Assert.near(actual[i], expected[i], 1e-9, (label or "texMatrix") .. " cell " .. tostring(i))
  end
end

local IDENTITY = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

-- ---- texture-swap clock ----

-- Construction leaves the runtime material on the base image -- never the
-- first replacement entry's image -- acquires every replacement image under
-- the material's wrap, and consumes no tick.
function T.initial_base_image_is_left_in_place_and_no_tick_is_consumed()
  local base = "base.png"
  local record = swapRecord(0, "flower01", base, flowerSteps())
  local resolve, calls, images = fakeImageResolver()
  local list = bindings({ record }, resolve)
  local runtime = list[1].runtime
  local animator = TerrainMaterialAnimator.new(list, false, resolve)
  Assert.notNil(animator.updateFixed)
  for _, step in ipairs(flowerSteps()) do
    assertResolved(calls, step.texture, "repeat", "repeat")
  end
  Assert.equal(runtime.image, images[base .. "@repeat|repeat"], "the runtime material keeps the base image")
  animator:updateFixed()
  Assert.equal(
    runtime.image,
    images[base .. "@repeat|repeat"],
    "the first switch comes only after the first step's 18 ticks"
  )
end

-- A zero-duration step follows the same state machine: the transition fires
-- on the very first update because zero ticks have already elapsed.
function T.zero_duration_step_transitions_on_the_first_update()
  local record = swapRecord(0, "flower", "base.png", {
    { texture = "r0.png", durationTicks = 0 },
    { texture = "r1.png", durationTicks = 1 },
  })
  local resolve, _, images = fakeImageResolver()
  local list = bindings({ record }, resolve)
  local runtime = list[1].runtime
  local animator = TerrainMaterialAnimator.new(list, false, resolve)
  animator:updateFixed()
  Assert.equal(runtime.image, images["r1.png@repeat|repeat"], "a zero-duration step crosses on update 1")
end

-- The exact field-manager counter behavior for an 18-tick step: the first
-- switch lands on the 19th update, every later step gets its own full 18
-- ticks, and the cursor wraps to step 1 on the 73rd update (72 ticks per
-- cycle for the r0,r1,r0,r2 schedule).
function T.boundary_ticks_of_an_18_tick_step_follow_the_clock()
  local record = swapRecord(0, "flower01", "base.png", flowerSteps())
  local resolve, _, images = fakeImageResolver()
  local list = bindings({ record }, resolve)
  local runtime = list[1].runtime
  local animator = TerrainMaterialAnimator.new(list, false, resolve)
  local function image()
    return runtime.image
  end
  local function advance(ticks)
    for _ = 1, ticks do
      animator:updateFixed()
    end
  end
  advance(18)
  Assert.equal(image(), images["base.png@repeat|repeat"], "step 1 (R0) runs its full 18 ticks")
  advance(1)
  Assert.equal(image(), images["r1.png@repeat|repeat"], "the first switch is exactly at tick 19")
  advance(17)
  Assert.equal(image(), images["r1.png@repeat|repeat"], "step 2 (R1) runs its full 18 ticks")
  advance(1)
  Assert.equal(image(), images["r0.png@repeat|repeat"], "step 3 (R0) begins at tick 37")
  advance(18)
  Assert.equal(image(), images["r2.png@repeat|repeat"], "step 4 (R2) begins at tick 55")
  advance(17)
  Assert.equal(image(), images["r2.png@repeat|repeat"], "step 4 runs its full 18 ticks")
  advance(1)
  Assert.equal(image(), images["r0.png@repeat|repeat"], "the cursor wraps to step 1 at tick 73")
end

-- Same-name materials may hold different replacement paths (neighbors
-- compile against their own packs): one clock drives the group -- every
-- member stays in phase -- and on a switch each material selects the entry
-- from its own preloaded array.
function T.same_name_materials_select_their_own_paths_in_phase()
  local a = swapRecord(0, "flower", "base-a.png", {
    { texture = "a0.png", durationTicks = 18 },
    { texture = "a1.png", durationTicks = 18 },
    { texture = "a2.png", durationTicks = 18 },
  })
  local b = swapRecord(1, "flower", "base-b.png", {
    { texture = "b0.png", durationTicks = 18 },
    { texture = "b1.png", durationTicks = 18 },
    { texture = "b2.png", durationTicks = 18 },
  })
  local resolve, _, images = fakeImageResolver()
  local list = bindings({ a, b }, resolve)
  local animator = TerrainMaterialAnimator.new(list, false, resolve)
  for _ = 1, 19 do
    animator:updateFixed()
  end
  Assert.equal(list[1].runtime.image, images["a1.png@repeat|repeat"], "member a enters step 2 at tick 19")
  Assert.equal(list[2].runtime.image, images["b1.png@repeat|repeat"], "member b enters step 2 at tick 19")
  for _ = 1, 18 do
    animator:updateFixed()
  end
  Assert.equal(list[1].runtime.image, images["a2.png@repeat|repeat"], "member a enters step 3 at tick 37")
  Assert.equal(list[2].runtime.image, images["b2.png@repeat|repeat"], "member b enters step 3 at tick 37")
  for _ = 1, 18 do
    animator:updateFixed()
  end
  Assert.equal(list[1].runtime.image, images["a0.png@repeat|repeat"], "member a wraps to step 1 at tick 55")
  Assert.equal(list[2].runtime.image, images["b0.png@repeat|repeat"], "member b wraps to step 1 at tick 55")
end

-- ---- texture-SRT playback ----

-- The SRT clock starts at frame 0: the targeted material's matrix is the
-- frame-0 sample at construction, advances one frame per updateFixed, and
-- the looping player wraps at frameCount. A transS of one fx32 unit moves
-- the UV by exactly one normalized texture width (m02 = -1 at frame 1).
function T.srt_starts_at_frame_zero_changes_after_one_update_and_loops_at_frame_count()
  local clip = scrollClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local record = staticRecord(0, "water", { texture = "water.png" })
  local resolve, _, _ = fakeImageResolver()
  local list = bindings({ record }, resolve)
  local animator = TerrainMaterialAnimator.new(list, clip, resolve)
  Assert.near(list[1].runtime.texMatrix[7], 0, 1e-9, "frame 0 samples the identity matrix")
  animator:updateFixed()
  Assert.near(list[1].runtime.texMatrix[7], -1, 1e-9, "frame 1 scrolls one full texture width")
  animator:updateFixed()
  Assert.near(list[1].runtime.texMatrix[7], -2, 1e-9, "frame 2 scrolls two texture widths")
  Assert.near(list[1].runtime.texMatrix[1], 1, 1e-9)
  Assert.near(list[1].runtime.texMatrix[5], 1, 1e-9)
  Assert.near(list[1].runtime.texMatrix[8], 0, 1e-9)
  animator:updateFixed()
  animator:updateFixed()
  Assert.near(list[1].runtime.texMatrix[7], 0, 1e-9, "the loop wraps at frameCount back to frame 0")
end

-- A targeted material's matrix follows the clip; an untargeted material
-- keeps its base matrix (the same table object) across updates; an
-- untextured material carries the identity matrix untouched.
function T.targeted_and_untargeted_materials_behave_independently()
  local clip = scrollClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local srt = {
    scaleS = 0x1000,
    scaleT = 0x1000,
    transS = 0x100,
    transT = 0,
    scaleOne = true,
    rotOne = true,
    transOne = false,
  }
  local water = staticRecord(0, "water", { texture = "water.png" })
  local flower = staticRecord(1, "flower", { texture = "flower.png", srt = srt })
  local plain = staticRecord(2, "plain", { texture = nil, texWidth = 0, texHeight = 0 })
  local resolve, _, _ = fakeImageResolver()
  local list = bindings({ water, flower, plain }, resolve)
  local animator = TerrainMaterialAnimator.new(list, clip, resolve)
  Assert.near(list[2].runtime.texMatrix[7], -1 / 16, 1e-9, "untargeted material holds its static base matrix")
  local flowerMatrix = list[2].runtime.texMatrix
  local plainMatrix = list[3].runtime.texMatrix
  animator:updateFixed()
  animator:updateFixed()
  animator:updateFixed()
  Assert.near(list[1].runtime.texMatrix[7], -3, 1e-9, "the targeted material follows the clip")
  Assert.equal(list[2].runtime.texMatrix, flowerMatrix, "untargeted matrix is never replaced")
  Assert.near(list[2].runtime.texMatrix[7], -1 / 16, 1e-9, "untargeted matrix value unchanged")
  Assert.equal(list[3].runtime.texMatrix, plainMatrix, "untextured matrix is never replaced")
  for i = 1, 9 do
    Assert.near(list[3].runtime.texMatrix[i], IDENTITY[i], 1e-9)
  end
end

-- Every binding gets its static matrix at construction even with no clip
-- and no swap: a fully static scene still initializes texMatrix from the
-- record's static srt (or identity when absent).
function T.static_srt_is_initialized_for_every_binding_without_a_clip()
  local srt = {
    scaleS = 0x1000,
    scaleT = 0x1000,
    transS = 0x100,
    transT = 0,
    scaleOne = true,
    rotOne = true,
    transOne = false,
  }
  local static = staticRecord(0, "soil", { texture = "soil.png", srt = srt })
  local plain = staticRecord(1, "plain", { texture = nil, texWidth = 0, texHeight = 0 })
  local resolve, _, _ = fakeImageResolver()
  local list = bindings({ static, plain }, resolve)
  local animator = TerrainMaterialAnimator.new(list, false, resolve)
  assertMatrixEqual(list[1].runtime.texMatrix, TextureSrtEvaluator.matrix(static, nil), "static srt")
  Assert.near(list[1].runtime.texMatrix[7], -1 / 16, 1e-9, "the static srt matrix is non-identity")
  assertMatrixEqual(list[2].runtime.texMatrix, TextureSrtEvaluator.matrix(plain, nil), "no srt")
  local matrix = list[1].runtime.texMatrix
  animator:updateFixed()
  Assert.equal(list[1].runtime.texMatrix, matrix, "no clip leaves matrices untouched")
end

-- ---- ownership ----

-- updateFixed performs no image acquisition: every resolver call happened at
-- construction, and several updates spanning multiple switches and SRT
-- frames add none.
function T.no_image_resolver_call_during_update_fixed()
  local clip = scrollClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local swap = swapRecord(0, "flower", "base.png", flowerSteps())
  local water = staticRecord(1, "water", { texture = "water.png" })
  local resolve, calls, _ = fakeImageResolver()
  local list = bindings({ swap, water }, resolve)
  local animator = TerrainMaterialAnimator.new(list, clip, resolve)
  Assert.isTrue(#calls > 0, "construction acquires the swap-step images")
  local callsAtConstruction = #calls
  for _ = 1, 80 do
    animator:updateFixed()
  end
  Assert.equal(#calls, callsAtConstruction, "no resolver call during updateFixed")
end

return { tests = T }
