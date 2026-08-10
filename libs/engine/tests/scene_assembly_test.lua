-- Tests for SceneAssembly, the one submission-order owner for the flattened
-- scene: it assigns monotonically increasing submission indices in desired
-- source order -- map, buildings, neighbours, actors -- so no producer keeps
-- a numeric base, and it returns copies so repeated assembly never mutates
-- the producers' persistent draw records. Equal-depth translucent ties are
-- resolved by those assembled indices, so cross-group tie order is decided
-- here and nowhere else.

local Assert = require("tests.support.Assert")
local SceneAssembly = require("libs.engine.src.SceneAssembly")
local RenderQueue = require("libs.engine.src.RenderQueue")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function item(id, mode)
  return {
    id = id,
    alphaClass = mode,
    center = { 0, 0, 0 },
    transform = Matrix4.identity(),
  }
end

function T.assigns_monotonic_submissions_across_parts_in_source_order()
  local flat = SceneAssembly.flatten({
    { item("map-a", "opaque"), item("map-b", "opaque") },
    { item("building", "cutout") },
    { item("neighbor-a", "translucent"), item("neighbor-b", "translucent") },
    { item("actor", "translucent") },
  })
  Assert.equal(#flat, 6)
  Assert.equal(flat[1].id, "map-a")
  Assert.equal(flat[2].id, "map-b")
  Assert.equal(flat[3].id, "building")
  Assert.equal(flat[4].id, "neighbor-a")
  Assert.equal(flat[5].id, "neighbor-b")
  Assert.equal(flat[6].id, "actor")
  for index, draw in ipairs(flat) do
    Assert.equal(draw.submissionIndex, index, "submission " .. index .. " is monotonic in source order")
  end
end

function T.empty_parts_yield_an_empty_list()
  Assert.deepEqual(SceneAssembly.flatten({}), {})
  Assert.deepEqual(SceneAssembly.flatten({ {}, {} }), {})
end

-- Repeated assembly must not add or change fields on the producers'
-- persistent draw records (the RenderQueue no-mutation principle applies to
-- the whole ordering pipeline, not just the queue).
function T.flatten_does_not_mutate_input_items()
  local items = { item("a", "opaque"), item("b", "translucent") }
  local before = {}
  for i, it in ipairs(items) do
    before[i] = {}
    for k, v in pairs(it) do
      before[i][k] = v
    end
  end
  SceneAssembly.flatten({ items })
  SceneAssembly.flatten({ items })
  for i, it in ipairs(items) do
    Assert.isNil(rawget(it, "submissionIndex"), "no submission number is attached to input item " .. i)
    Assert.deepEqual(it, before[i], "input item " .. i .. " mutated by assembly")
  end
end

-- Assembly returns stamped copies, never the producers' tables, so per-frame
-- numbering cannot leak back into persistent scene state.
function T.flatten_returns_copies_not_the_original_items()
  local map = item("map", "opaque")
  local actor = item("actor", "translucent")
  local flat = SceneAssembly.flatten({ { map }, { actor } })
  Assert.isTrue(flat[1] ~= map, "flatten returns a copy of each draw item")
  Assert.isTrue(flat[2] ~= actor, "flatten returns a copy of each draw item")
  Assert.equal(flat[1].id, "map")
  Assert.equal(flat[1].submissionIndex, 1)
  Assert.equal(flat[2].submissionIndex, 2)
end

-- An item that already carries a submission number (a producer that still
-- kept one) is renumbered by the assembly: the assembler is the authority.
function T.flatten_overwrites_pre_existing_submission_indices()
  local item = item("map", "opaque")
  item.submissionIndex = 200000
  local flat = SceneAssembly.flatten({ { item } })
  Assert.equal(flat[1].submissionIndex, 1)
  Assert.equal(rawget(item, "submissionIndex"), 200000, "the input's own number is untouched")
end

-- Two translucent draws at the same camera depth tie-break by assembled
-- submission order: the earlier part (map geometry) draws before the later
-- part (actors) regardless of which came first in the flat list's creation.
function T.equal_depth_translucent_ties_follow_assembly_order()
  local view = Matrix4.lookAt({ 0, 0, 5 }, { 0, 0, 0 }, { 0, 1, 0 })
  local map = item("map", "translucent")
  local neighbor = item("neighbor", "translucent")
  local actor = item("actor", "translucent")
  local flat = SceneAssembly.flatten({
    { map },
    { neighbor },
    { actor },
  })
  local queue = RenderQueue.build(flat, view)
  Assert.equal(#queue.translucent, 3)
  Assert.equal(queue.translucent[1].id, "map")
  Assert.equal(queue.translucent[2].id, "neighbor")
  Assert.equal(queue.translucent[3].id, "actor")
end

-- The assembled order also drives the opaque/cutout/wireframe pass order.
function T.opaque_passes_preserve_assembly_order()
  local flat = SceneAssembly.flatten({
    { item("neighbor", "opaque") },
    { item("map", "opaque") },
    { item("actor", "opaque") },
  })
  local queue = RenderQueue.build(flat, Matrix4.identity())
  Assert.equal(queue.opaque[1].id, "neighbor")
  Assert.equal(queue.opaque[2].id, "map")
  Assert.equal(queue.opaque[3].id, "actor")
end

return T
