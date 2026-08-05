-- Tests for RenderQueue: classification, submission-order preservation for
-- opaque/cutout/wireframe, translucent back-to-front sorting, and deterministic
-- tie-breaking.

local Assert = require("tests.support.Assert")
local RenderQueue = require("libs.engine.src.RenderQueue")
local Matrix4 = require("libs.engine.src.Matrix4")

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
  for _, it in ipairs(queue[key]) do out[#out + 1] = it.submissionIndex end
  return out
end

function T.classifies_by_alpha_class()
  local items = {
    item(1, "opaque"), item(2, "cutout"), item(3, "translucent"),
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
    item(1, "translucent", { 0, 0, 0 }),    -- nearest
    item(2, "translucent", { 0, 0, -10 }),  -- farthest
    item(3, "translucent", { 0, 0, -5 }),   -- middle
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

return T
