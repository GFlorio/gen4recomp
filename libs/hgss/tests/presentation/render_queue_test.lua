-- Tests for RenderQueue: classification, pass-order preservation for
-- opaque/cutout/mixedOpaque/wireframe, translucent back-to-front sorting,
-- MIXED item splitting into opaque and blended passes, and deterministic
-- tie-breaking by traversal position across ordered parts. Queue construction
-- validates its input contract and never mutates the caller's draw records.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local RenderQueue = require("libs.hgss.src.presentation.RenderQueue")
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
  local entries = queue[key]
  if key == "blended" then
    -- blended contains {item, fragmentPass, viewZ, position} records
    for _, record in ipairs(entries) do
      out[#out + 1] = record.item.id
    end
  else
    for _, it in ipairs(entries) do
      out[#out + 1] = it.id
    end
  end
  return out
end

local function fragmentPassesIn(queue, key)
  local out = {}
  if key == "blended" then
    for _, record in ipairs(queue[key]) do
      out[#out + 1] = record.fragmentPass
    end
  end
  return out
end

local function scratch()
  return {
    opaque = {},
    cutout = {},
    mixedOpaque = {},
    wireframe = {},
    blended = {},
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
  Assert.deepEqual(ids(q, "blended"), { "c" })
  Assert.deepEqual(ids(q, "wireframe"), { "d" })
end

function T.classifies_mixed_items()
  local items = {
    item("mixed1", "mixed"),
    item("mixed2", "mixed"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.deepEqual(ids(q, "mixedOpaque"), { "mixed1", "mixed2" })
  -- Mixed items also appear in blended with fragmentPass
  Assert.deepEqual(ids(q, "blended"), { "mixed1", "mixed2" })
  Assert.deepEqual(
    fragmentPassesIn(q, "blended"),
    { "mixed", "mixed" },
    "mixed items in blended have fragmentPass='mixed'"
  )
end

function T.build_into_reuses_caller_owned_scratch_arrays()
  local storage = scratch()
  local opaque = storage.opaque
  local cutout = storage.cutout
  local mixedOpaque = storage.mixedOpaque
  local wireframe = storage.wireframe
  local blended = storage.blended

  local queue = RenderQueue.buildInto({
    { item("map", "opaque"), item("glass", "translucent") },
    { item("building", "cutout") },
    { item("actor", "wireframe") },
  }, Matrix4.identity(), storage)

  Assert.isTrue(queue == storage)
  Assert.isTrue(queue.opaque == opaque)
  Assert.isTrue(queue.cutout == cutout)
  Assert.isTrue(queue.mixedOpaque == mixedOpaque)
  Assert.isTrue(queue.wireframe == wireframe)
  Assert.isTrue(queue.blended == blended)
  Assert.deepEqual(ids(queue, "opaque"), { "map" })
  Assert.deepEqual(ids(queue, "cutout"), { "building" })
  Assert.deepEqual(ids(queue, "blended"), { "glass" })
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
  Assert.equal(#storage.mixedOpaque, 0)
  Assert.equal(#storage.wireframe, 0)
  Assert.equal(#storage.blended, 0)
end

function T.build_into_translucent_ties_preserve_cross_part_order()
  local queue = RenderQueue.buildInto({
    { item("map", "translucent", { 0, 0, -5 }) },
    { item("building", "translucent", { 0, 0, -5 }) },
    { item("neighbor", "translucent", { 0, 0, -5 }) },
    { item("actor", "translucent", { 0, 0, -5 }) },
  }, Matrix4.identity(), scratch())

  Assert.deepEqual(ids(queue, "blended"), { "map", "building", "neighbor", "actor" })
end

function T.mixed_and_translucent_sort_jointly_by_view_z()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local queue = RenderQueue.buildInto({
    {
      item("trans-far", "translucent", { 0, 0, -10 }),
      item("mixed-mid", "mixed", { 0, 0, -5 }),
      item("trans-near", "translucent", { 0, 0, -1 }),
    },
  }, view, scratch())

  Assert.deepEqual(ids(queue, "blended"), { "trans-far", "mixed-mid", "trans-near" })
  Assert.deepEqual(fragmentPassesIn(queue, "blended"), { "translucent", "mixed", "translucent" })
end

function T.mixed_and_translucent_equal_depth_tie_by_position()
  local queue = RenderQueue.buildInto({
    { item("trans1", "translucent", { 0, 0, -5 }) },
    { item("mixed1", "mixed", { 0, 0, -5 }) },
    { item("trans2", "translucent", { 0, 0, -5 }) },
    { item("mixed2", "mixed", { 0, 0, -5 }) },
  }, Matrix4.identity(), scratch())

  Assert.deepEqual(
    ids(queue, "blended"),
    { "trans1", "mixed1", "trans2", "mixed2" },
    "equal-depth items maintain submission order"
  )
end

function T.mixed_item_in_opaque_and_blended_passes()
  local storage = scratch()
  local queue = RenderQueue.buildInto({
    {
      item("opaque", "opaque"),
      item("mixed", "mixed"),
      item("translucent", "translucent"),
    },
  }, Matrix4.identity(), storage)

  -- Mixed appears in mixedOpaque for the opaque subpass
  Assert.deepEqual(ids(queue, "mixedOpaque"), { "mixed" })
  -- Mixed also appears in blended for the translucent subpass
  Assert.deepEqual(ids(queue, "blended"), { "mixed", "translucent" })
  -- Verify fragmentPass markers
  Assert.deepEqual(fragmentPassesIn(queue, "blended"), { "mixed", "translucent" })
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
  Assert.deepEqual(ids(q, "blended"), { "farthest", "middle", "nearest" })
end

-- Equal-depth blended draws tie-break by traversal position across the
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
  Assert.deepEqual(ids(q, "blended"), { "first", "second", "third" })
end

function T.transforms_center_by_item_transform()
  -- Two items at the same model-space center but translated differently.
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local near = item("near", "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, 0))
  local far = item("far", "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, -10))
  local q = build({ { near, far } }, view)
  Assert.deepEqual(ids(q, "blended"), { "far", "near" })
end

function T.transforms_nonzero_model_center_once_before_sorting()
  local translated = item("translated", "translucent", { 0, 0, 1 }, Matrix4.translate(0, 0, 32))
  local origin = item("origin", "translucent", { 0, 0, 49 }, Matrix4.identity())
  local q = build({ { translated, origin } }, Matrix4.identity())
  Assert.deepEqual(ids(q, "blended"), { "translated", "origin" })
end

-- Sorting must not attach fields (e.g. a cached `_viewZ`) to the persistent
-- draw records, and repeated construction must not change any input item.
-- Blended entries are scratch records, but original items remain untouched.
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
  Assert.deepEqual(ids(first, "blended"), ids(second, "blended"))
end

-- The returned queue holds the original item tables in opaque/cutout/mixedOpaque/wireframe.
-- Blended entries are scratch records that point to original items via .item field.
function T.queue_entries_are_the_original_items()
  local items = {
    item("a", "opaque"),
    item("b", "translucent"),
    item("c", "cutout"),
    item("d", "wireframe"),
  }
  local q = build({ items }, Matrix4.identity())
  Assert.isTrue(q.opaque[1] == items[1], "opaque pass returns the original item")
  Assert.isTrue(q.blended[1].item == items[2], "blended pass record points to original item")
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
  Assert.deepEqual(ids(q, "blended"), { 1, 2 }, "far (rotated) first, near origin last")
end

function T.sorts_billboards_from_their_view_space_center_and_scaled_model_center()
  local billboard = item("billboard", "translucent", { 0, 0, 1 })
  billboard.billboardCenter = { 0, 0, -32 }
  billboard.billboardScale = { 1, 1, 2 }
  local ordinary = item("ordinary", "translucent", { 0, 0, -29.5 })

  local q = build({ { billboard, ordinary } }, Matrix4.identity())

  Assert.deepEqual(
    ids(q, "blended"),
    { "billboard", "ordinary" },
    "billboard depth includes its view-space center and scaled model center"
  )
end

-- Blended entries are renderer-owned scratch records with {item, fragmentPass, viewZ, position}.
-- They must be reused across frames so repeated queue construction does not
-- allocate new entry tables.
function T.blended_entries_are_reused_scratch_records()
  local storage = scratch()
  local q1 = RenderQueue.buildInto({
    { item("trans1", "translucent"), item("trans2", "translucent") },
  }, Matrix4.identity(), storage)

  local firstEntry1 = q1.blended[1]
  local firstEntry2 = q1.blended[2]

  local q2 = RenderQueue.buildInto({
    { item("trans1", "translucent"), item("trans2", "translucent") },
  }, Matrix4.identity(), storage)

  -- Same storage object is reused
  Assert.isTrue(q2 == storage)
  -- Scratch entry tables are reused (same object identities)
  Assert.isTrue(q2.blended[1] == firstEntry1, "blended entry 1 table is reused")
  Assert.isTrue(q2.blended[2] == firstEntry2, "blended entry 2 table is reused")
end

-- After a smaller frame, stale blended entries must be truncated.
function T.blended_tail_truncation_after_smaller_frame()
  local storage = scratch()
  RenderQueue.buildInto({
    {
      item("t1", "translucent"),
      item("t2", "translucent"),
      item("t3", "translucent"),
    },
  }, Matrix4.identity(), storage)

  Assert.equal(#storage.blended, 3)

  RenderQueue.buildInto({
    { item("t1", "translucent") },
  }, Matrix4.identity(), storage)

  Assert.equal(#storage.blended, 1, "stale blended tail is removed")
end

-- Blended records must have fragmentPass field set to the correct pass type.
function T.blended_records_have_fragment_pass_field()
  local storage = scratch()
  RenderQueue.buildInto({
    {
      item("trans", "translucent"),
      item("mixed", "mixed"),
    },
  }, Matrix4.identity(), storage)

  Assert.equal(storage.blended[1].fragmentPass, "translucent")
  Assert.equal(storage.blended[2].fragmentPass, "mixed")
end

-- MIXED items must not be in the translucent-only array, and must appear separately.
function T.mixed_does_not_confuse_with_translucent_only()
  local storage = scratch()
  local items = {
    item("trans-a", "translucent"),
    item("mixed-a", "mixed"),
    item("trans-b", "translucent"),
    item("mixed-b", "mixed"),
  }
  RenderQueue.buildInto({ items }, Matrix4.identity(), storage)

  -- mixedOpaque contains only mixed items
  Assert.deepEqual(ids(storage, "mixedOpaque"), { "mixed-a", "mixed-b" })
  -- blended contains all items (mixed + translucent)
  Assert.deepEqual(ids(storage, "blended"), { "trans-a", "mixed-a", "trans-b", "mixed-b" })
  -- Verify the fragmentPass values
  Assert.deepEqual(fragmentPassesIn(storage, "blended"), { "translucent", "mixed", "translucent", "mixed" })
end

return { tests = T }
