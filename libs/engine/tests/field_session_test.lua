-- Fixed-step session tests prove deterministic tick counts, catch-up capping,
-- and that the camera consumes the placeholder actor's continuous 3D target.

local Assert = require("tests.support.Assert")
local FieldSession = require("libs.engine.src.FieldSession")

local T = {}

local function session()
  local targets = {}
  local camera = { updateFixed = function(_, target)
    targets[#targets + 1] = { x = target.x, y = target.y, z = target.z }
  end }
  local actor = { worldX = 1.25, worldY = 2.5, worldZ = 3.75 }
  return FieldSession.new({ versionId = "heartgold", currentMap = { mapId = 61 },
    actor = actor, camera = camera }), targets
end

function T.fixed_ticks_are_render_cadence_independent()
  local a = session()
  a:update(1 / 30)
  local b = session()
  b:update(1 / 60)
  b:update(1 / 60)
  Assert.equal(a.tick, 2)
  Assert.equal(b.tick, 2)
end

function T.caps_catch_up_and_counts_discarded_ticks()
  local s = session()
  s:update(10 / 60)
  Assert.equal(s.tick, 5)
  Assert.equal(s.discardedTicks, 5)
end

function T.camera_follows_the_actor_xyz_each_fixed_tick()
  local s, targets = session()
  s:update(1 / 60)
  Assert.deepEqual(targets[1], { x = 1.25, y = 2.5, z = 3.75 })
end

function T.trace_is_identical_across_render_delta_patterns()
  local function run(pattern)
    local records = {}
    local actor = {
      fieldX = 1, fieldZ = 2, worldX = 0, worldY = 0, worldZ = 0,
      surfaceId = 3, facing = "north", motion = "walking",
    }
    function actor:updateFixed()
      self.worldY = self.worldY + 0.125
    end
    local camera = {
      updateFixed = function(self, target)
        self.cameraSourceY, self.cameraAppliedY = target.y, target.y
      end,
    }
    local s = FieldSession.new({
      versionId = "heartgold", currentMap = { mapId = 60, cameraType = 0 },
      actor = actor, player = actor, camera = camera,
      trace = function(record) records[#records + 1] = record end,
    })
    for _, dt in ipairs(pattern) do s:update(dt, {}) end
    return records
  end
  local sixtieths = {}
  local oneTwentieths = {}
  for _ = 1, 24 do sixtieths[#sixtieths + 1] = 1 / 60 end
  for _ = 1, 8 do oneTwentieths[#oneTwentieths + 1] = 1 / 20 end
  Assert.deepEqual(run(sixtieths), run(oneTwentieths))
end

return T
