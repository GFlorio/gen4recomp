-- Field navigation must use the session physical world only for outdoor
-- composed views; indoor/discontinuous maps keep their own transition path.

local Assert = require("tests.support.Assert")
local FieldNavigationBoundary = require("libs.engine.src.FieldNavigationBoundary")

local T = { tests = {} }

function T.tests.does_not_reuse_outdoor_world_for_indoor_maps()
  local boundary = FieldNavigationBoundary.new({
    physicalWorld = {
      mapHeaderAt = function()
        error("indoor movement must not query outdoor coverage")
      end,
    },
  })
  local runtimeMap = { scene = { type = "indoor" } }
  local player = { fieldX = 0, fieldZ = 0 }

  Assert.isFalse(boundary:crossesLogicalZone(runtimeMap, player, "north"))
  Assert.isNil(boundary:afterCommittedMove(runtimeMap, player, {}))
end

return T
