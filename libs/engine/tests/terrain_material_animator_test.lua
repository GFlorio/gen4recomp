-- TerrainMaterialAnimator tests: the terrain texture-swap clock (the field
-- manager's per-tick counter state machine over the compiled fldtanime
-- schedule) and the looping area texture-SRT playback (the compiled NSBTA
-- clip), composed over scene-form material records and the runtime material
-- tables the loaders' draw items reference. Construction must select frame 0
-- without advancing either clock, acquire every swap-frame image once, and
-- never mutate the generated descriptor records; updateFixed must advance
-- each shared clock exactly once, assign only preloaded images, and perform
-- no acquisition. The texture-matrix math is pinned against the existing
-- MaterialEvaluator behavior through ModelInstance, so the extracted
-- TextureSrtEvaluator must compose identically. Pure domain; no rendering,
-- no love.

local Assert = require("tests.support.Assert")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
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

-- The new-bark-like swap schedule: 0 for 18 ticks, 1 for 18, 0 for 18,
-- 2 for 18, loop (a four-entry cycle of 72 ticks).
local function flowerTimeline()
  return {
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 1, durationTicks = 18 },
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 2, durationTicks = 18 },
  }
end

-- A scene-form terrain material with a texture-swap descriptor; the frame-0
-- invariant of the generated contract (textures[1] == material.texture)
-- holds by construction.
local function swapRecord(id, name, textures, timeline)
  return {
    id = id,
    name = name,
    texture = textures[1],
    wrap = { x = "repeat", y = "repeat" },
    texWidth = 16,
    texHeight = 16,
    texMtxMode = 0,
    textureSwap = {
      name = name,
      textures = textures,
      timeline = timeline,
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

-- The runtime material tables draw items reference: one per record id, with
-- the image and texMatrix the animator owns.
local function runtimeMaterials(records)
  local byId = {}
  for _, record in ipairs(records) do
    byId[record.id] = { id = record.id, name = record.name, image = nil, texMatrix = nil }
  end
  return byId
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

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepCopy(v)
  end
  return out
end

local function assertMatrixEqual(actual, expected, label)
  for i = 1, 9 do
    Assert.near(actual[i], expected[i], 1e-9, (label or "texMatrix") .. " cell " .. tostring(i))
  end
end

local IDENTITY = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

-- ---- texture-swap clock ----

-- Construction selects frame 0: the runtime material carries the preloaded
-- first-schedule image, every alternate image was acquired under the
-- material's wrap, the base texMatrix is set, and no tick has run (the image
-- is still the frame-0 entry after construction, not the frame-1 entry).
function T.construction_selects_frame_zero_and_does_not_advance()
  local textures = { "a.png", "b.png", "c.png" }
  local record = swapRecord(0, "flower01", textures, flowerTimeline())
  local runtime = runtimeMaterials({ record })
  local resolve, calls, images = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new({ record }, runtime, false, resolve)
  Assert.notNil(animator.updateFixed)
  for _, path in ipairs(textures) do
    assertResolved(calls, path, "repeat", "repeat")
  end
  Assert.equal(runtime[0].image, images["a.png@repeat|repeat"], "frame-0 image selected at construction")
  for i = 1, 9 do
    Assert.near(runtime[0].texMatrix[i], IDENTITY[i], 1e-9)
  end
  -- One update later the clock advances: construction consumed no tick.
  animator:updateFixed()
  Assert.equal(runtime[0].image, images["a.png@repeat|repeat"], "first switch comes after the entry's 18 ticks")
end

-- The exact field-manager counter behavior for an 18-tick entry: the first
-- switch lands on the 19th update, every later entry gets its own full 18
-- ticks, and the cursor wraps to entry 1 on the 73rd update (72 ticks per
-- cycle for the 0,1,0,2 schedule).
function T.boundary_ticks_of_an_18_tick_entry_follow_the_clock()
  local textures = { "a.png", "b.png", "c.png" }
  local record = swapRecord(0, "flower01", textures, flowerTimeline())
  local runtime = runtimeMaterials({ record })
  local resolve, _, images = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new({ record }, runtime, false, resolve)
  local function image()
    return runtime[0].image
  end
  local function advance(ticks)
    for _ = 1, ticks do
      animator:updateFixed()
    end
  end
  advance(18)
  Assert.equal(image(), images["a.png@repeat|repeat"], "entry 1 (index 0) runs its full 18 ticks")
  advance(1)
  Assert.equal(image(), images["b.png@repeat|repeat"], "first switch is exactly at tick 19")
  advance(17)
  Assert.equal(image(), images["b.png@repeat|repeat"], "entry 2 (index 1) runs its full 18 ticks")
  advance(1)
  Assert.equal(image(), images["a.png@repeat|repeat"], "entry 3 (index 0) begins at tick 37")
  advance(18)
  Assert.equal(image(), images["c.png@repeat|repeat"], "entry 4 (index 2) begins at tick 55")
  advance(17)
  Assert.equal(image(), images["c.png@repeat|repeat"], "entry 4 runs its full 18 ticks")
  advance(1)
  Assert.equal(image(), images["a.png@repeat|repeat"], "the cursor wraps to entry 1 at tick 73")
end

-- Adjacent entries with the same textureIndex are distinct schedule entries:
-- each contributes its own duration window. The schedule 0 for 18, 0 for 18,
-- 1 for 18 must switch to index 1 at tick 37, not at tick 19 as a collapsed
-- pair would.
function T.repeated_texture_index_zero_entries_follow_the_schedule()
  local textures = { "a.png", "b.png" }
  local record = swapRecord(0, "flower01", textures, {
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 1, durationTicks = 18 },
  })
  local runtime = runtimeMaterials({ record })
  local resolve, _, images = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new({ record }, runtime, false, resolve)
  local function image()
    return runtime[0].image
  end
  local function advance(ticks)
    for _ = 1, ticks do
      animator:updateFixed()
    end
  end
  advance(18)
  Assert.equal(image(), images["a.png@repeat|repeat"])
  advance(18)
  Assert.equal(image(), images["a.png@repeat|repeat"], "the second index-0 entry runs its own 18-tick window")
  advance(1)
  Assert.equal(image(), images["b.png@repeat|repeat"], "index 1 begins at tick 37, after both index-0 windows")
  advance(17)
  Assert.equal(image(), images["b.png@repeat|repeat"])
  advance(1)
  Assert.equal(image(), images["a.png@repeat|repeat"], "the three-entry cycle wraps at tick 55")
end

-- Two materials sharing one animation name stay in phase: one shared
-- cursor/counter drives both runtime tables, so every switch lands on the
-- same tick with the same index.
function T.two_materials_in_one_group_remain_in_phase()
  local textures = { "a.png", "b.png", "c.png" }
  local a = swapRecord(0, "flower", textures, flowerTimeline())
  local b = swapRecord(1, "flower", textures, flowerTimeline())
  local runtime = runtimeMaterials({ a, b })
  local resolve, _, images = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new({ a, b }, runtime, false, resolve)
  for _ = 1, 18 do
    animator:updateFixed()
  end
  Assert.equal(runtime[0].image, images["a.png@repeat|repeat"])
  Assert.equal(runtime[1].image, images["a.png@repeat|repeat"])
  animator:updateFixed()
  Assert.equal(runtime[0].image, images["b.png@repeat|repeat"], "both materials switch at tick 19")
  Assert.equal(runtime[1].image, images["b.png@repeat|repeat"])
  for _ = 1, 54 do
    animator:updateFixed()
  end
  Assert.equal(runtime[0].image, images["a.png@repeat|repeat"], "both materials wrap at tick 73")
  Assert.equal(runtime[1].image, images["a.png@repeat|repeat"])
end

-- Same-name materials may hold different image arrays (neighbors compile
-- against their own texture packs): one cursor/counter drives the group, and
-- on a switch each material selects the entry's zero-based index from its
-- own array.
function T.same_name_materials_select_corresponding_indices_from_their_own_arrays()
  local a = swapRecord(0, "flower", { "a0.png", "a1.png", "a2.png" }, flowerTimeline())
  local b = swapRecord(1, "flower", { "b0.png", "b1.png", "b2.png" }, flowerTimeline())
  local runtime = runtimeMaterials({ a, b })
  local resolve, _, images = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new({ a, b }, runtime, false, resolve)
  for _ = 1, 19 do
    animator:updateFixed()
  end
  Assert.equal(runtime[0].image, images["a1.png@repeat|repeat"])
  Assert.equal(runtime[1].image, images["b1.png@repeat|repeat"], "index 1 of its own array at tick 19")
  for _ = 1, 36 do
    animator:updateFixed()
  end
  Assert.equal(runtime[0].image, images["a2.png@repeat|repeat"])
  Assert.equal(runtime[1].image, images["b2.png@repeat|repeat"], "index 2 of its own array at tick 55")
  for _ = 1, 18 do
    animator:updateFixed()
  end
  Assert.equal(runtime[0].image, images["a0.png@repeat|repeat"])
  Assert.equal(runtime[1].image, images["b0.png@repeat|repeat"], "index 0 of its own array after the wrap")
end

-- Equal animation names must not carry conflicting timelines: any structural
-- difference is a runtime programming invariant violation, including two
-- timelines that describe the same schedule through different entry
-- structure (no normalization/collapse is allowed before the comparison).
function T.conflicting_same_name_timelines_fail()
  local a = swapRecord(0, "flower", { "a.png", "b.png" }, {
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 1, durationTicks = 18 },
  })
  local b = swapRecord(1, "flower", { "a.png", "b.png" }, {
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 1, durationTicks = 9 },
    { textureIndex = 1, durationTicks = 9 },
  })
  Assert.throws(function()
    TerrainMaterialAnimator.new({ a, b }, runtimeMaterials({ a, b }), false, fakeImageResolver())
  end, "conflicting timelines must fail construction")
end

function T.structurally_different_but_equivalent_timelines_fail()
  local a = swapRecord(0, "flower", { "a.png", "b.png" }, {
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 0, durationTicks = 18 },
    { textureIndex = 1, durationTicks = 18 },
  })
  local b = swapRecord(1, "flower", { "a.png", "b.png" }, {
    { textureIndex = 0, durationTicks = 36 },
    { textureIndex = 1, durationTicks = 18 },
  })
  Assert.throws(function()
    TerrainMaterialAnimator.new({ a, b }, runtimeMaterials({ a, b }), false, fakeImageResolver())
  end, "timelines must be compared structurally, never collapsed")
end

-- Same-name materials with differently sized image arrays cannot share one
-- cursor: construction must fail instead of silently selecting one array.
function T.differently_sized_texture_arrays_fail()
  local a = swapRecord(0, "flower", { "a0.png", "a1.png", "a2.png" }, flowerTimeline())
  local b = swapRecord(1, "flower", { "b0.png", "b1.png" }, flowerTimeline())
  Assert.throws(function()
    TerrainMaterialAnimator.new({ a, b }, runtimeMaterials({ a, b }), false, fakeImageResolver())
  end, "differently sized arrays in one group must fail construction")
end

-- ---- texture-SRT playback ----

-- The SRT clock starts at frame 0: the targeted material's matrix is the
-- frame-0 sample at construction, advances one frame per updateFixed, and
-- the looping player wraps at frameCount. A transS of one fx32 unit moves
-- the UV by exactly one normalized texture width (m02 = -1 at frame 1).
function T.srt_starts_at_frame_zero_changes_after_one_update_and_loops_at_frame_count()
  local clip = scrollClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local record = staticRecord(0, "water", { texture = "water.png" })
  local runtime = runtimeMaterials({ record })
  local resolve, _, _ = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new({ record }, runtime, clip, resolve)
  Assert.near(runtime[0].texMatrix[7], 0, 1e-9, "frame 0 samples the identity matrix")
  animator:updateFixed()
  Assert.near(runtime[0].texMatrix[7], -1, 1e-9, "frame 1 scrolls one full texture width")
  animator:updateFixed()
  Assert.near(runtime[0].texMatrix[7], -2, 1e-9, "frame 2 scrolls two texture widths")
  Assert.near(runtime[0].texMatrix[1], 1, 1e-9)
  Assert.near(runtime[0].texMatrix[5], 1, 1e-9)
  Assert.near(runtime[0].texMatrix[8], 0, 1e-9)
  animator:updateFixed()
  animator:updateFixed()
  Assert.near(runtime[0].texMatrix[7], 0, 1e-9, "the loop wraps at frameCount back to frame 0")
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
    transOne = false,
  }
  local water = staticRecord(0, "water", { texture = "water.png" })
  local flower = staticRecord(1, "flower", { texture = "flower.png", srt = srt })
  local plain = staticRecord(2, "plain", { texture = nil, texWidth = 0, texHeight = 0 })
  local records = { water, flower, plain }
  local runtime = runtimeMaterials(records)
  local resolve, _, _ = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new(records, runtime, clip, resolve)
  Assert.near(runtime[1].texMatrix[7], -1 / 16, 1e-9, "untargeted material holds its static base matrix")
  local flowerMatrix = runtime[1].texMatrix
  local plainMatrix = runtime[2].texMatrix
  animator:updateFixed()
  animator:updateFixed()
  animator:updateFixed()
  Assert.near(runtime[0].texMatrix[7], -3, 1e-9, "the targeted material follows the clip")
  Assert.equal(runtime[1].texMatrix, flowerMatrix, "untargeted matrix is never replaced")
  Assert.near(runtime[1].texMatrix[7], -1 / 16, 1e-9, "untargeted matrix value unchanged")
  Assert.equal(runtime[2].texMatrix, plainMatrix, "untextured matrix is never replaced")
  for i = 1, 9 do
    Assert.near(runtime[2].texMatrix[i], IDENTITY[i], 1e-9)
  end
end

-- ---- parity with the existing MaterialEvaluator ----

-- The base (static-SRT) composition must be bit-equivalent to the matrix the
-- existing dynamic-model evaluator builds for the same material fields, and
-- the extracted TextureSrtEvaluator must expose that composition directly.
function T.base_srt_composes_exactly_like_material_evaluator()
  local variants = {
    {
      label = "non-identity",
      srt = {
        scaleS = 0x1800,
        scaleT = 0x1000,
        transS = 0x200,
        transT = 0x100,
        rot = { sin = 0x400, cos = 0xE00 },
        scaleOne = false,
        transOne = false,
        rotOne = false,
      },
    },
    {
      label = "no-rotation",
      srt = {
        scaleS = 0x1000,
        scaleT = 0x1000,
        transS = 0x100,
        transT = 0,
        scaleOne = true,
        transOne = false,
      },
    },
    { label = "absent", srt = nil },
  }
  for _, variant in ipairs(variants) do
    local record = staticRecord(0, "soil", { texture = "soil.png", srt = variant.srt })
    local runtime = runtimeMaterials({ record })
    local resolve, _, _ = fakeImageResolver()
    local animator = TerrainMaterialAnimator.new({ record }, runtime, false, resolve)
    local definition = ModelDefinition.new({
      key = "fixture:soil",
      nodes = {
        {
          index = 0,
          name = "root",
          translation = { x = 0, y = 0, z = 0 },
          rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
          scale = { x = 1, y = 1, z = 1 },
        },
      },
      meshes = { { id = "m", nodeIndex = 0, materialIndex = 0, geometry = "fixtures/m.g4mesh" } },
      materials = {
        {
          id = 0,
          name = "soil",
          baseColor = { r = 255, g = 255, b = 255, a = 255 },
          alphaMode = "opaque",
          doubleSided = false,
          texture = "soil.png",
          texWidth = 16,
          texHeight = 16,
          textureFormat = 3,
          alphaUsage = { hasZero = true },
          polygonAlpha = 31,
          texMtxMode = 0,
          srt = variant.srt,
        },
      },
      skins = {},
      animations = {},
    })
    local instance = ModelInstance.new(definition)
    instance:evaluateMaterials()
    assertMatrixEqual(runtime[0].texMatrix, instance.materialState[0].texMatrix, variant.label .. " animator")
    assertMatrixEqual(
      TextureSrtEvaluator.matrix(record, nil),
      instance.materialState[0].texMatrix,
      variant.label .. " evaluator"
    )
  end
end

-- The sampled composition must be bit-equivalent to the existing evaluator
-- at every frame: the animator's player and the instance's attachment player
-- advance in lockstep, and a static srt is replaced by the clip sample.
function T.sampled_srt_composes_exactly_like_material_evaluator()
  local clip = scrollClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local srt = {
    scaleS = 0x1800,
    scaleT = 0x1000,
    transS = 0x200,
    transT = 0x100,
    rot = { sin = 0x400, cos = 0xE00 },
    scaleOne = false,
    transOne = false,
    rotOne = false,
  }
  local record = staticRecord(0, "water", { texture = "water.png", srt = srt })
  local runtime = runtimeMaterials({ record })
  local resolve, _, _ = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new({ record }, runtime, clip, resolve)
  local definition = ModelDefinition.new({
    key = "fixture:water",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = { { id = "m", nodeIndex = 0, materialIndex = 0, geometry = "fixtures/m.g4mesh" } },
    materials = {
      {
        id = 0,
        name = "water",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
        texture = "water.png",
        texWidth = 16,
        texHeight = 16,
        textureFormat = 3,
        alphaUsage = { hasZero = true },
        polygonAlpha = 31,
        texMtxMode = 0,
        srt = srt,
      },
    },
    skins = {},
    animations = { clip },
  })
  local instance = ModelInstance.new(definition)
  instance:play("scroll")
  instance:evaluateMaterials()
  assertMatrixEqual(
    runtime[0].texMatrix,
    instance.materialState[0].texMatrix,
    "frame 0 replaces the static srt with the sample"
  )
  for frame = 1, 3 do
    instance:updateFixed()
    instance:evaluateMaterials()
    animator:updateFixed()
    assertMatrixEqual(runtime[0].texMatrix, instance.materialState[0].texMatrix, "frame " .. tostring(frame))
  end
end

-- ---- ownership and immutability ----

-- Construction and playback never mutate the generated descriptor records or
-- the compiled clip: the animator consumes them read-only.
function T.generated_descriptors_are_unchanged_after_construction_and_updates()
  local clip = scrollClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local swap = swapRecord(0, "flower", { "a.png", "b.png", "c.png" }, flowerTimeline())
  local water = staticRecord(1, "water", { texture = "water.png" })
  local records = { swap, water }
  local clipCopy = deepCopy(clip)
  local recordsCopy = deepCopy(records)
  local runtime = runtimeMaterials(records)
  local resolve, _, _ = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new(records, runtime, clip, resolve)
  for _ = 1, 80 do
    animator:updateFixed()
  end
  Assert.deepEqual(clip, clipCopy, "clip")
  Assert.deepEqual(records, recordsCopy, "records")
end

-- updateFixed performs no image acquisition: every resolver call happened at
-- construction, and several updates spanning multiple switches and SRT
-- frames add none.
function T.no_image_resolver_call_during_update_fixed()
  local clip = scrollClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local swap = swapRecord(0, "flower", { "a.png", "b.png", "c.png" }, flowerTimeline())
  local water = staticRecord(1, "water", { texture = "water.png" })
  local runtime = runtimeMaterials({ swap, water })
  local resolve, calls, _ = fakeImageResolver()
  local animator = TerrainMaterialAnimator.new({ swap, water }, runtime, clip, resolve)
  Assert.isTrue(#calls > 0, "construction acquires the swap-frame images")
  local callsAtConstruction = #calls
  for _ = 1, 80 do
    animator:updateFixed()
  end
  Assert.equal(#calls, callsAtConstruction, "no resolver call during updateFixed")
end

return { tests = T }
