-- Fixed-tick input snapshots choose one held direction deterministically,
-- expose each new press exactly once for the movement buffer, and carry the
-- semantic Action/Cancel buttons as separate edges and held state. Action
-- and Cancel track their physical sources: a semantic button stays down
-- until every pressed source is released, and a repeat press from an
-- already-held source never produces a new edge.

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.engine.src.FieldInput")

local T = {}

function T.latest_press_wins_until_released()
  local input = FieldInput.new()
  input:press("north")
  input:press("east")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = "east", pressedDirection = "east", actionDown = false, cancelDown = false }
  )
  Assert.deepEqual(input:snapshot(), { heldDirection = "east", actionDown = false, cancelDown = false })
  input:release("east")
  Assert.deepEqual(input:snapshot(), { heldDirection = "north", actionDown = false, cancelDown = false })
end

function T.repeated_press_does_not_create_another_edge()
  local input = FieldInput.new()
  input:press("south")
  input:snapshot()
  input:press("south")
  Assert.deepEqual(input:snapshot(), { heldDirection = "south", actionDown = false, cancelDown = false })
end

function T.rejects_unknown_directions()
  local input = FieldInput.new()
  Assert.throws(function()
    input:press("up")
  end)
end

function T.rejects_missing_sources()
  local input = FieldInput.new()
  Assert.throws(function()
    ---@diagnostic disable-next-line: missing-parameter -- intentional: a missing source must raise
    input:pressAction()
  end)
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- intentional: a nil source must raise
    input:pressCancel(nil)
  end)
  Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- intentional: a non-string source must raise
    input:releaseAction(42)
  end)
  Assert.throws(function()
    input:releaseCancel("")
  end)
end

function T.action_edge_fires_once_while_held_state_persists()
  local input = FieldInput.new()
  input:pressAction("key:z")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false }
  )
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false })
  input:releaseAction("key:z")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false })
end

function T.cancel_edge_is_separate_from_action()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:pressAction("key:z")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = true, cancelPressed = true }
  )
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = true })
  input:releaseCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false })
end

function T.clear_edges_keeps_held_state()
  local input = FieldInput.new()
  input:press("west")
  input:pressAction("key:z")
  input:clearEdges()
  Assert.deepEqual(input:snapshot(), { heldDirection = "west", actionDown = true, cancelDown = false })
  input:releaseAction("key:z")
  input:release("west")
end

function T.clear_all_drops_edges_and_held_state()
  local input = FieldInput.new()
  input:press("north")
  input:pressAction("key:z")
  input:pressCancel("key:x")
  input:clearAll()
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false })
end

function T.action_stays_down_until_last_keyboard_source_released()
  local input = FieldInput.new()
  input:pressAction("key:enter")
  input:pressAction("key:space")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false }
  )
  input:releaseAction("key:enter")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false })
  input:releaseAction("key:space")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false })
end

function T.action_stays_down_across_keyboard_and_gamepad_sources()
  local input = FieldInput.new()
  input:pressAction("key:space")
  input:pressAction("gamepad:1:a")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false }
  )
  input:releaseAction("key:space")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false })
  input:releaseAction("gamepad:1:a")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false })
end

function T.repeat_press_from_held_action_source_creates_no_new_edge()
  local input = FieldInput.new()
  input:pressAction("key:space")
  input:snapshot()
  input:pressAction("key:space")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = true, cancelDown = false })
end

function T.cancel_stays_down_until_last_keyboard_source_released()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:pressCancel("key:backspace")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true }
  )
  input:releaseCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = true })
  input:releaseCancel("key:backspace")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false })
end

function T.cancel_stays_down_across_keyboard_and_gamepad_sources()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:pressCancel("gamepad:0:b")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true }
  )
  input:releaseCancel("gamepad:0:b")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = true })
  input:releaseCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false })
end

function T.repeat_press_from_held_cancel_source_creates_no_new_edge()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:snapshot()
  input:pressCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = true })
end

function T.action_edge_occurs_only_on_semantic_rise()
  local input = FieldInput.new()
  input:pressAction("key:z")
  input:pressAction("key:space")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false }
  )
  input:releaseAction("key:z")
  input:releaseAction("key:space")
  input:pressAction("key:z")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true, cancelDown = false }
  )
end

function T.cancel_edge_occurs_only_on_semantic_rise()
  local input = FieldInput.new()
  input:pressCancel("key:x")
  input:pressCancel("key:backspace")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true }
  )
  input:releaseCancel("key:x")
  input:releaseCancel("key:backspace")
  input:pressCancel("key:x")
  Assert.deepEqual(
    input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = true, cancelPressed = true }
  )
end

function T.focus_loss_clears_all_physical_sources()
  local input = FieldInput.new()
  input:pressAction("key:enter")
  input:pressAction("gamepad:0:a")
  input:pressCancel("key:x")
  input:clearAll()
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false })
  input:releaseAction("key:enter")
  input:releaseAction("gamepad:0:a")
  input:releaseCancel("key:x")
  Assert.deepEqual(input:snapshot(), { heldDirection = nil, actionDown = false, cancelDown = false })
end

return T
