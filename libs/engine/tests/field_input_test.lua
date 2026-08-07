-- Fixed-tick input snapshots choose one held direction deterministically,
-- expose each new press exactly once for the movement buffer, and carry the
-- semantic Action/Cancel buttons as separate edges and held state (spec
-- section 11.1-11.2).

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.engine.src.FieldInput")

local T = {}

function T.latest_press_wins_until_released()
  local input = FieldInput.new()
  input:press("north")
  input:press("east")
  Assert.deepEqual(input:snapshot(),
    { heldDirection = "east", pressedDirection = "east",
      actionDown = false, cancelDown = false })
  Assert.deepEqual(input:snapshot(),
    { heldDirection = "east", actionDown = false, cancelDown = false })
  input:release("east")
  Assert.deepEqual(input:snapshot(),
    { heldDirection = "north", actionDown = false, cancelDown = false })
end

function T.repeated_press_does_not_create_another_edge()
  local input = FieldInput.new()
  input:press("south")
  input:snapshot()
  input:press("south")
  Assert.deepEqual(input:snapshot(),
    { heldDirection = "south", actionDown = false, cancelDown = false })
end

function T.rejects_unknown_directions()
  local input = FieldInput.new()
  Assert.throws(function() input:press("up") end)
end

function T.action_edge_fires_once_while_held_state_persists()
  local input = FieldInput.new()
  input:pressAction()
  Assert.deepEqual(input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true,
      cancelDown = false })
  Assert.deepEqual(input:snapshot(),
    { heldDirection = nil, actionDown = true, cancelDown = false })
  input:releaseAction()
  Assert.deepEqual(input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false })
end

function T.cancel_edge_is_separate_from_action()
  local input = FieldInput.new()
  input:pressCancel()
  input:pressAction()
  Assert.deepEqual(input:snapshot(),
    { heldDirection = nil, actionDown = true, actionPressed = true,
      cancelDown = true, cancelPressed = true })
  Assert.deepEqual(input:snapshot(),
    { heldDirection = nil, actionDown = true, cancelDown = true })
  input:releaseCancel()
  Assert.deepEqual(input:snapshot(),
    { heldDirection = nil, actionDown = true, cancelDown = false })
end

function T.clear_edges_keeps_held_state()
  local input = FieldInput.new()
  input:press("west")
  input:pressAction()
  input:clearEdges()
  Assert.deepEqual(input:snapshot(),
    { heldDirection = "west", actionDown = true, cancelDown = false })
  input:releaseAction()
  input:release("west")
end

function T.clear_all_drops_edges_and_held_state()
  local input = FieldInput.new()
  input:press("north")
  input:pressAction()
  input:pressCancel()
  input:clearAll()
  Assert.deepEqual(input:snapshot(),
    { heldDirection = nil, actionDown = false, cancelDown = false })
end

return T
