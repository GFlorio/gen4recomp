-- Fixed-tick input snapshots choose one held direction deterministically and
-- expose each new press exactly once for the movement buffer.

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.engine.src.FieldInput")

local T = {}

function T.latest_press_wins_until_released()
  local input = FieldInput.new()
  input:press("north")
  input:press("east")
  Assert.deepEqual(input:snapshot(), { heldDirection = "east", pressedDirection = "east" })
  Assert.deepEqual(input:snapshot(), { heldDirection = "east" })
  input:release("east")
  Assert.deepEqual(input:snapshot(), { heldDirection = "north" })
end

function T.repeated_press_does_not_create_another_edge()
  local input = FieldInput.new()
  input:press("south")
  input:snapshot()
  input:press("south")
  Assert.deepEqual(input:snapshot(), { heldDirection = "south" })
end

function T.rejects_unknown_directions()
  local input = FieldInput.new()
  Assert.throws(function() input:press("up") end)
end

return T
