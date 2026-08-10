-- Tests for RenderQueue: classification, submission-order preservation for
-- opaque/cutout/wireframe, translucent back-to-front sorting, and deterministic
-- tie-breaking. Queue construction validates its input contract -- only the
-- four known alpha classes, an integer submission index on every item -- and
-- never mutates the caller's draw records.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local RenderQueue = require("libs.engine.src.RenderQueue")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function item(index, mode, center, transform)
  return {
    submissionIndex = index,
    alphaClass = mode,
    center = center or { 0, 0, 0 },
    transform = transform or Matrix4.identity(),
  }
end

local function ids(queue, key)
  local out = {}
  for _, it in ipairs(queue[key]) do
    out[#out + 1] = it.submissionIndex
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
    item(1, "opaque"),
    item(2, "cutout"),
    item(3, "translucent"),
    item(4, "wireframe"),
  }
  local q = RenderQueue.build(items, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { 1 })
  Assert.deepEqual(ids(q, "cutout"), { 2 })
  Assert.deepEqual(ids(q, "translucent"), { 3 })
  Assert.deepEqual(ids(q, "wireframe"), { 4 })
end

function T.falls_back_to_material_alpha_class()
  local matItem = {
    submissionIndex = 1,
    alphaClass = nil,
    material = { alphaClass = "cutout" },
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  local q = RenderQueue.build({ matItem }, Matrix4.identity())
  Assert.deepEqual(ids(q, "cutout"), { 1 })
end

function T.rejects_unknown_alpha_class()
  local err = throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    RenderQueue.build({ item(1, "ghostly") }, Matrix4.identity())
  end)
  Assert.equal(err.context.alphaClass, "ghostly")
end

function T.rejects_missing_alpha_class()
  local bare = {
    submissionIndex = 1,
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    RenderQueue.build({ bare }, Matrix4.identity())
  end)
end

function T.rejects_unknown_material_alpha_class()
  local matItem = {
    submissionIndex = 1,
    material = { alphaClass = "shiny" },
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  throwsCode("RENDER_QUEUE_UNKNOWN_ALPHA_CLASS", function()
    RenderQueue.build({ matItem }, Matrix4.identity())
  end)
end

function T.preserves_submission_order_for_opaque()
  local items = { item(1, "opaque"), item(2, "opaque"), item(3, "opaque") }
  local q = RenderQueue.build(items, Matrix4.identity())
  Assert.deepEqual(ids(q, "opaque"), { 1, 2, 3 })
end

function T.preserves_submission_order_for_cutout_and_wireframe()
  local items = { item(1, "cutout"), item(2, "wireframe"), item(3, "cutout") }
  local q = RenderQueue.build(items, Matrix4.identity())
  Assert.deepEqual(ids(q, "cutout"), { 1, 3 })
  Assert.deepEqual(ids(q, "wireframe"), { 2 })
end

function T.sorts_translucent_back_to_front()
  -- Camera at (0,0,5) looking at origin; view matrix maps world +Z to -Z.
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local items = {
    item(1, "translucent", { 0, 0, 0 }), -- nearest
    item(2, "translucent", { 0, 0, -10 }), -- farthest
    item(3, "translucent", { 0, 0, -5 }), -- middle
  }
  local q = RenderQueue.build(items, view)
  Assert.deepEqual(ids(q, "translucent"), { 2, 3, 1 })
end

function T.uses_submission_index_as_tie_breaker()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local items = {
    item(3, "translucent", { 0, 0, -5 }),
    item(1, "translucent", { 0, 0, -5 }),
    item(2, "translucent", { 0, 0, -5 }),
  }
  local q = RenderQueue.build(items, view)
  Assert.deepEqual(ids(q, "translucent"), { 1, 2, 3 })
end

function T.transforms_center_by_item_transform()
  -- Two items at the same model-space center but translated differently.
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local near = item(1, "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, 0))
  local far = item(2, "translucent", { 0, 0, 0 }, Matrix4.translate(0, 0, -10))
  local q = RenderQueue.build({ near, far }, view)
  Assert.deepEqual(ids(q, "translucent"), { 2, 1 })
end

function T.missing_submission_index_fails()
  local noIndex = {
    alphaClass = "opaque",
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
  throwsCode("RENDER_QUEUE_SUBMISSION_INVALID", function()
    RenderQueue.build({ noIndex }, Matrix4.identity())
  end)
end

function T.non_integer_submission_indices_fail()
  local function buildWith(index)
    local it = item(index, "opaque")
    return function()
      RenderQueue.build({ it }, Matrix4.identity())
    end
  end
  throwsCode("RENDER_QUEUE_SUBMISSION_INVALID", buildWith(1.5))
  throwsCode("RENDER_QUEUE_SUBMISSION_INVALID", buildWith(0 / 0))
  throwsCode("RENDER_QUEUE_SUBMISSION_INVALID", buildWith(math.huge))
end

-- Sorting must not attach fields (e.g. a cached `_viewZ`) to the persistent
-- draw records, and repeated construction must not change any input item.
function T.build_does_not_mutate_input_items()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local items = {
    item(1, "opaque", { 0, 0, 0 }),
    item(2, "translucent", { 0, 0, -10 }),
    item(3, "translucent", { 0, 0, -5 }),
    item(4, "cutout"),
    item(5, "wireframe"),
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
    item(1, "opaque"),
    item(2, "translucent"),
    item(3, "cutout"),
    item(4, "wireframe"),
  }
  local q = RenderQueue.build(items, Matrix4.identity())
  Assert.isTrue(q.opaque[1] == items[1], "opaque pass returns the original item")
  Assert.isTrue(q.translucent[1] == items[2], "translucent pass returns the original item")
  Assert.isTrue(q.cutout[1] == items[3], "cutout pass returns the original item")
  Assert.isTrue(q.wireframe[1] == items[4], "wireframe pass returns the original item")
end

return T
