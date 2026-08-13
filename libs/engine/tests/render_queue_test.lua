-- Tests for RenderQueue: classification, pass-order preservation for
-- opaque/cutout/wireframe, translucent back-to-front sorting, and
-- deterministic tie-breaking by the item's position in the flat scene list
-- (the assembly's submission order). Queue construction validates its input
-- contract -- only the four known alpha classes -- and never mutates the
-- caller's draw records.

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
  local q = RenderQueue.build(items, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { "a" })
  Assert.deepEqual(ids(q, "cutout"), { "b" })
  Assert.deepEqual(ids(q, "translucent"), { "c" })
  Assert.deepEqual(ids(q, "wireframe"), { "d" })
end

function T.falls_back_to_material_alpha_class()
  local matItem = {
    id = "mat",
    alphaClass = nil,
    material = { alphaClass = "cutout" },
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  local q = RenderQueue.build({ matItem }, Matrix4.identity())
  Assert.deepEqual(ids(q, "cutout"), { "mat" })
end

function T.rejects_unknown_alpha_class()
  local err = throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    RenderQueue.build({ item("ghostly", "ghostly") }, Matrix4.identity())
  end)
  Assert.equal(err.context.alphaClass, "ghostly")
end

function T.rejects_missing_alpha_class()
  local bare = {
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    RenderQueue.build({ bare }, Matrix4.identity())
  end)
end

function T.rejects_unknown_material_alpha_class()
  local matItem = {
    material = { alphaClass = "shiny" },
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    RenderQueue.build({ matItem }, Matrix4.identity())
  end)
end

function T.preserves_submission_order_for_opaque()
  local items = { item("a", "opaque"), item("b", "opaque"), item("c", "opaque") }
  local q = RenderQueue.build(items, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { "a", "b", "c" })
end

function T.preserves_submission_order_for_cutout_and_wireframe()
  local items = { item("a", "cutout"), item("b", "wireframe"), item("c", "cutout") }
  local q = RenderQueue.build(items, Matrix4.identity())
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
  local q = RenderQueue.build(items, view)
  Assert.deepEqual(ids(q, "translucent"), { "farthest", "middle", "nearest" })
end

-- Equal-depth translucent draws tie-break by the item's position in the flat
-- scene list: that position is the assembly's submission order, so the
-- earlier part (map geometry) draws before the later part (actors) no matter
-- how the list was produced.
function T.equal_depth_ties_break_by_flat_list_position()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local items = {
    item("first", "translucent", { 0, 0, -5 }),
    item("second", "translucent", { 0, 0, -5 }),
    item("third", "translucent", { 0, 0, -5 }),
  }
  local q = RenderQueue.build(items, view)
  Assert.deepEqual(ids(q, "translucent"), { "first", "second", "third" })
end

function T.transforms_center_by_item_transform()
  -- Two items at the same model-space center but translated differently.
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local near = item("near", "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, 0))
  local far = item("far", "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, -10))
  local q = RenderQueue.build({ near, far }, view)
  Assert.deepEqual(ids(q, "translucent"), { "far", "near" })
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
  local first = RenderQueue.build(items, view)
  local second = RenderQueue.build(items, view)
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
  local q = RenderQueue.build(items, Matrix4.identity())
  Assert.isTrue(q.opaque[1] == items[1], "opaque pass returns the original item")
  Assert.isTrue(q.translucent[1] == items[2], "translucent pass returns the original item")
  Assert.isTrue(q.cutout[1] == items[3], "cutout pass returns the original item")
  Assert.isTrue(q.wireframe[1] == items[4], "wireframe pass returns the original item")
end

return T
