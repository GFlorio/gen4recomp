-- Tests for RenderQueue: classification, pass-order preservation for
-- opaque/cutout/wireframe, translucent back-to-front sorting, and
-- deterministic tie-breaking by traversal position across ordered parts.
-- Queue construction validates its input contract -- only the four known
-- alpha classes -- and never mutates the caller's draw records.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local RenderQueue = require("libs.engine.src.RenderQueue")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function item(id, mode, center, transform)
  return {
    id = id,
    alphaClass = mode,
    center = center or { 0, 0, 0 },
    transform = transform or Matrix4.identity(),
  }
end

local function ids(queue, key)
  local out = {}
  for _, it in ipairs(queue[key]) do
    out[#out + 1] = it.id
  end
  return out
end

local function scratch()
  return {
    opaque = {},
    cutout = {},
    translucent = {},
    wireframe = {},
    translucentEntries = {},
  }
end

local function build(parts, viewMatrix)
  return RenderQueue.buildInto(parts, viewMatrix, scratch())
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(
    Errors.is(err) and err.code == code,
    "expected " .. code .. ", got " .. tostring(Errors.is(err) and err.code or err)
  )
  return err
end

function T.classifies_by_alpha_class()
  local items = {
    item("a", "opaque"),
    item("b", "cutout"),
    item("c", "translucent"),
    item("d", "wireframe"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { "a" })
  Assert.deepEqual(ids(q, "cutout"), { "b" })
  Assert.deepEqual(ids(q, "translucent"), { "c" })
  Assert.deepEqual(ids(q, "wireframe"), { "d" })
end

function T.build_into_reuses_caller_owned_scratch_arrays()
  local storage = scratch()
  local opaque = storage.opaque
  local cutout = storage.cutout
  local translucent = storage.translucent
  local wireframe = storage.wireframe
  local entries = storage.translucentEntries

  local queue = RenderQueue.buildInto({
    { item("map", "opaque"), item("glass", "translucent") },
    { item("building", "cutout") },
    { item("actor", "wireframe") },
  }, Matrix4.identity(), storage)

  Assert.isTrue(queue == storage)
  Assert.isTrue(queue.opaque == opaque)
  Assert.isTrue(queue.cutout == cutout)
  Assert.isTrue(queue.translucent == translucent)
  Assert.isTrue(queue.wireframe == wireframe)
  Assert.isTrue(queue.translucentEntries == entries)
  Assert.deepEqual(ids(queue, "opaque"), { "map" })
  Assert.deepEqual(ids(queue, "cutout"), { "building" })
  Assert.deepEqual(ids(queue, "translucent"), { "glass" })
  Assert.deepEqual(ids(queue, "wireframe"), { "actor" })
end

function T.build_into_preserves_order_across_parts()
  local queue = RenderQueue.buildInto({
    { item("map-a", "opaque"), item("map-b", "cutout") },
    { item("building", "opaque") },
    { item("neighbor", "cutout") },
    { item("actor", "opaque") },
  }, Matrix4.identity(), scratch())

  Assert.deepEqual(ids(queue, "opaque"), { "map-a", "building", "actor" })
  Assert.deepEqual(ids(queue, "cutout"), { "map-b", "neighbor" })
end

function T.build_into_clears_stale_tail_entries()
  local storage = scratch()
  RenderQueue.buildInto({
    {
      item("opaque-a", "opaque"),
      item("opaque-b", "opaque"),
      item("cutout", "cutout"),
      item("far", "translucent", { 0, 0, -2 }),
      item("near", "translucent", { 0, 0, -1 }),
      item("wire", "wireframe"),
    },
  }, Matrix4.identity(), storage)

  RenderQueue.buildInto({ { item("only", "opaque") } }, Matrix4.identity(), storage)

  Assert.deepEqual(ids(storage, "opaque"), { "only" })
  Assert.equal(#storage.cutout, 0)
  Assert.equal(#storage.translucent, 0)
  Assert.equal(#storage.wireframe, 0)
  Assert.equal(#storage.translucentEntries, 0)
end

function T.build_into_translucent_ties_preserve_cross_part_order()
  local queue = RenderQueue.buildInto({
    { item("map", "translucent", { 0, 0, -5 }) },
    { item("building", "translucent", { 0, 0, -5 }) },
    { item("neighbor", "translucent", { 0, 0, -5 }) },
    { item("actor", "translucent", { 0, 0, -5 }) },
  }, Matrix4.identity(), scratch())

  Assert.deepEqual(ids(queue, "translucent"), { "map", "building", "neighbor", "actor" })
end

function T.rejects_material_only_alpha_class()
  local matItem = {
    id = "mat",
    alphaClass = nil,
    material = { alphaClass = "cutout" },
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  local err = throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    build({ { matItem } }, Matrix4.identity())
  end)
  Assert.isNil(err.context.alphaClass)
end

function T.rejects_unknown_alpha_class()
  local err = throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    build({ { item("ghostly", "ghostly") } }, Matrix4.identity())
  end)
  Assert.equal(err.context.alphaClass, "ghostly")
end

function T.rejects_missing_alpha_class()
  local bare = {
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    build({ { bare } }, Matrix4.identity())
  end)
end

function T.preserves_submission_order_for_opaque()
  local items = { item("a", "opaque"), item("b", "opaque"), item("c", "opaque") }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { "a", "b", "c" })
end

function T.preserves_submission_order_for_cutout_and_wireframe()
  local items = { item("a", "cutout"), item("b", "wireframe"), item("c", "cutout") }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "cutout"), { "a", "c" })
  Assert.deepEqual(ids(q, "wireframe"), { "b" })
end

function T.sorts_translucent_back_to_front()
  -- Camera at (0,0,5) looking at origin; view matrix maps world +Z to -Z.
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local items = {
    item("nearest", "translucent", { 0, 0, 0 }),
    item("farthest", "translucent", { 0, 0, -10 }),
    item("middle", "translucent", { 0, 0, -5 }),
  }
  local q = build({ items }, view)
  Assert.deepEqual(ids(q, "translucent"), { "farthest", "middle", "nearest" })
end

-- Equal-depth translucent draws tie-break by traversal position across the
-- ordered parts: the earlier part (map geometry) draws before the later part
-- (actors) deterministically.
function T.equal_depth_ties_break_by_part_position()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local parts = {
    { item("first", "translucent", { 0, 0, -5 }) },
    { item("second", "translucent", { 0, 0, -5 }) },
    { item("third", "translucent", { 0, 0, -5 }) },
  }
  local q = build(parts, view)
  Assert.deepEqual(ids(q, "translucent"), { "first", "second", "third" })
end

function T.transforms_center_by_item_transform()
  -- Two items at the same model-space center but translated differently.
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local near = item("near", "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, 0))
  local far = item("far", "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, -10))
  local q = build({ { near, far } }, view)
  Assert.deepEqual(ids(q, "translucent"), { "far", "near" })
end

function T.transforms_nonzero_model_center_once_before_sorting()
  local translated = item("translated", "translucent", { 0, 0, 1 }, Matrix4.translate(0, 0, 32))
  local origin = item("origin", "translucent", { 0, 0, 49 }, Matrix4.identity())
  local q = build({ { translated, origin } }, Matrix4.identity())
  Assert.deepEqual(ids(q, "translucent"), { "translated", "origin" })
end

-- Sorting must not attach fields (e.g. a cached `_viewZ`) to the persistent
-- draw records, and repeated construction must not change any input item.
function T.build_does_not_mutate_input_items()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local items = {
    item("a", "opaque", { 0, 0, 0 }),
    item("b", "translucent", { 0, 0, -10 }),
    item("c", "translucent", { 0, 0, -5 }),
    item("d", "cutout"),
    item("e", "wireframe"),
  }
  local before = {}
  for i, it in ipairs(items) do
    before[i] = {}
    for k, v in pairs(it) do
      before[i][k] = v
    end
  end
  local first = build({ items }, view)
  local second = build({ items }, view)
  for i, it in ipairs(items) do
    Assert.isNil(rawget(it, "_viewZ"), "no sort field is attached to item " .. i)
    Assert.deepEqual(it, before[i], "item " .. i .. " mutated by queue construction")
  end
  Assert.deepEqual(ids(first, "translucent"), ids(second, "translucent"))
end

-- The returned queue holds the original item tables, not decorated copies.
function T.queue_entries_are_the_original_items()
  local items = {
    item("a", "opaque"),
    item("b", "translucent"),
    item("c", "cutout"),
    item("d", "wireframe"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.isTrue(q.opaque[1] == items[1], "opaque pass returns the original item")
  Assert.isTrue(q.translucent[1] == items[2], "translucent pass returns the original item")
  Assert.isTrue(q.cutout[1] == items[3], "cutout pass returns the original item")
  Assert.isTrue(q.wireframe[1] == items[4], "wireframe pass returns the original item")
end

-- A rotated+translated item: the model-space center is transformed exactly
-- once by the item transform, so the sort reflects the true world position
-- (the dynamic-instance contract -- never a world-space center that the
-- queue would transform a second time).
function T.transforms_rotated_translated_centers_once()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local rotate = Matrix4.rotateY(math.pi / 2)
  local move = Matrix4.translate(0, 0, -10)
  local transform = Matrix4.multiply(move, rotate)
  -- A model-local center at +X maps, under the 90-degree Y rotation, to -Z:
  -- the world center is (0, 0, -10). An item at the origin stays nearer.
  local rotated = item(1, "translucent", { 5, 0, 0 }, transform)
  local origin = item(2, "translucent", { 0, 0, 0 }, Matrix4.identity())
  local q = build({ { origin, rotated } }, view)
  Assert.deepEqual(ids(q, "translucent"), { 1, 2 }, "far (rotated) first, near origin last")
end

return { tests = T }
