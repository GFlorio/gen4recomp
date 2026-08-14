-- The player visual adapter must read FieldPlayer and never write it: pose from
-- motion, facing from the player, interpolated world position from the shared
-- render position, and a deterministic clock that only advances mid-step.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldActorPose = require("libs.engine.src.FieldActorPose")
local FieldPlayer = require("libs.engine.src.FieldPlayer")
local FieldPlayerVisual = require("libs.engine.src.FieldPlayerVisual")
local TerrainSurface = require("libs.engine.src.TerrainSurface")

local T = {}

local function runtimeMap()
  return {
    mapId = 60,
    coordinateOrigin = { x = 0, z = 0 },
    collision = {
      containsLocal = function(_, x, z)
        return x >= 0 and x < 32 and z >= 0 and z < 32
      end,
      isBlockedLocal = function()
        return false
      end,
    },
    terrain = TerrainSurface.new({
      plates = {
        {
          id = 0,
          minX = 0,
          minZ = 0,
          maxX = 32,
          maxZ = 32,
          normal = { x = 0, y = 1, z = 0 },
          distance = 0,
          slopeClass = "flat",
        },
      },
    }),
  }
end

-- A FieldPlayer-shaped stub: the adapter must depend only on this surface.
local function player()
  return {
    facing = "south",
    motion = "idle",
    worldX = 2,
    worldY = 0.5,
    worldZ = 3,
    previousWorldX = 1,
    previousWorldY = 0.5,
    previousWorldZ = 3,
    renderPosition = function(self, alpha)
      alpha = alpha == nil and 1 or alpha
      return {
        x = self.previousWorldX + (self.worldX - self.previousWorldX) * alpha,
        y = self.previousWorldY + (self.worldY - self.previousWorldY) * alpha,
        z = self.previousWorldZ + (self.worldZ - self.previousWorldZ) * alpha,
      }
    end,
  }
end

-- A real FieldPlayer on an open flat map, for the tile-boundary phase tests.
local function movingPlayer()
  return FieldPlayer.new({ currentMap = runtimeMap(), fieldX = 0, fieldZ = 4, surfaceId = 0, facing = "south" })
end

-- Drive one full session-style tick: capture the pre-update walking state,
-- advance the player, then advance the visual with that capture.
local function walkTick(subject, presentation, direction)
  local walkingAtTickStart = subject.motion == "walking"
  subject:updateFixed({ heldDirection = direction, pressedDirection = direction })
  presentation:updateFixed(walkingAtTickStart)
end

local function visual(subject)
  return FieldPlayerVisual.new({
    player = subject,
    spriteId = 0,
  })
end

function T.stands_still_until_the_player_walks()
  local subject = player()
  local presentation = visual(subject)
  presentation:updateFixed()
  Assert.equal(presentation.pose, "idle")
  Assert.equal(presentation.poseTick, 0)

  subject.motion = "walking"
  presentation:updateFixed()
  presentation:updateFixed()
  Assert.equal(presentation.pose, "walk")
  Assert.equal(presentation.poseTick, 2, "the clock advances once per fixed tick while stepping")

  subject.motion = "idle"
  presentation:updateFixed()
  Assert.equal(presentation.pose, "idle")
  Assert.equal(presentation.poseTick, 0, "a settled player holds its facing's first frame")
end

function T.the_draw_record_interpolates_the_shared_render_position()
  local subject = player()
  local presentation = visual(subject)
  local record = presentation:drawRecord(0.5)
  Assert.equal(record.actorId, "field:player")
  Assert.equal(record.spriteId, 0)
  Assert.near(record.world.x, 1.5, 1e-9)
  Assert.equal(record.facing, "south")
  Assert.equal(record.pose, "idle")
  Assert.isTrue(record.visible)
end

function T.the_draw_record_and_world_table_are_reused_and_updated()
  local subject = player()
  local presentation = visual(subject)
  local record = presentation:drawRecord(0.5)
  subject.previousWorldX = 2
  subject.worldX = 5
  subject.facing = "east"

  local updated = presentation:drawRecord(1)
  Assert.isTrue(updated == record, "the player record is reusable")
  Assert.isTrue(updated.world == record.world, "the player world table is reusable")
  Assert.equal(updated.world.x, 5)
  Assert.equal(updated.facing, "east")
end

function T.the_record_follows_the_players_facing()
  local subject = player()
  local presentation = visual(subject)
  subject.facing = "east"
  Assert.equal(presentation:drawRecord(1).facing, "east")
end

function T.switching_avatar_restarts_the_pose_clock()
  local subject = player()
  local presentation = visual(subject)
  subject.motion = "walking"
  presentation:updateFixed()
  presentation:setAvatar(97)
  Assert.equal(presentation.spriteId, 97)
  Assert.equal(presentation.poseTick, 0, "a shorter atlas must not be indexed by the old clock")
end

function T.rejects_an_avatar_without_a_compiled_sprite_id()
  local subject = player()
  local err = Assert.throws(function()
    FieldPlayerVisual.new({ player = subject })
  end)
  Assert.isTrue(
    Errors.is(err) and err.code == "PLAYER_AVATAR_INVALID",
    "expected PLAYER_AVATAR_INVALID, got " .. tostring(err)
  )
end

-- A two-tile walk is the gait the ROM spans: the character animation range is
-- 16 ticks long, exactly two eight-tick walking tiles, so the phase must
-- survive the tile commit instead of restarting on every arrival.
function T.a_two_tile_walk_carries_the_phase_across_the_tile_commit()
  local subject = movingPlayer()
  local presentation = visual(subject)
  for tick = 1, 8 do
    walkTick(subject, presentation, "east")
  end
  Assert.equal(subject.motion, "idle", "the first tile committed")
  Assert.equal(subject.fieldX, 1)
  Assert.equal(presentation.pose, "walk", "the commit tick is still a walking tick")
  Assert.equal(presentation.poseTick, 8, "the phase holds through the tile boundary")

  for tick = 1, 8 do
    walkTick(subject, presentation, "east")
  end
  Assert.equal(subject.fieldX, 2, "the second tile committed")
  Assert.equal(presentation.pose, "walk")
  Assert.equal(presentation.poseTick, 16, "two tiles advance the full 16-tick cycle")
end

-- With the phase allowed to reach the full ROM range, every frame of that range
-- displays: frame 3 of a 16-tick range is unreachable if the clock resets every
-- eight ticks, which is exactly the bug this guards against.
function T.sixteen_continuous_ticks_traverse_the_entire_rom_range()
  local subject = movingPlayer()
  local def = FieldActorFixture.visual(0, { frameCount = 8 })
  for _, direction in pairs(def.directions) do
    direction.walk = {
      frames = {
        { frameIndex = 1, ticks = 4 },
        { frameIndex = 2, ticks = 4 },
        { frameIndex = 3, ticks = 4 },
        { frameIndex = 4, ticks = 4 },
      },
      loop = true,
      durationTicks = 16,
      sourceRange = { startFrame = 0, endFrame = 15, endMode = 0 },
    }
  end
  local presentation = FieldPlayerVisual.new({
    player = subject,
    spriteId = 0,
  })
  local framesAtTick = {}
  for tick = 1, 16 do
    walkTick(subject, presentation, "east")
    framesAtTick[tick] = FieldActorPose.frameIndex(def, "east", "walk", presentation.poseTick)
  end
  Assert.equal(presentation.poseTick, 16)
  Assert.equal(framesAtTick[8], 3, "the back half of the range is reachable mid-cycle")
  Assert.equal(framesAtTick[12], 4)
  Assert.equal(framesAtTick[16], 1, "the cycle wraps to its first frame")
end

function T.the_first_genuinely_idle_tick_resets_the_phase()
  local subject = movingPlayer()
  local presentation = visual(subject)
  for tick = 1, 8 do
    walkTick(subject, presentation, "east")
  end
  Assert.equal(presentation.poseTick, 8)
  Assert.equal(presentation.pose, "walk")

  local walkingAtTickStart = subject.motion == "walking"
  Assert.isFalse(walkingAtTickStart, "the player settled on the commit tick")
  subject:updateFixed({})
  presentation:updateFixed(walkingAtTickStart)
  Assert.equal(presentation.pose, "idle")
  Assert.equal(presentation.poseTick, 0, "only a genuinely idle tick resets the clock")
end

function T.changing_facing_during_continuous_movement_resets_the_phase()
  local subject = movingPlayer()
  local presentation = visual(subject)
  for tick = 1, 8 do
    walkTick(subject, presentation, "east")
  end
  Assert.equal(presentation.poseTick, 8)

  -- Turning mid-walk (buffered to the next step) must start the new facing's
  -- range at its first frame, not import the old range's phase.
  for tick = 1, 4 do
    walkTick(subject, presentation, "south")
  end
  Assert.equal(subject.facing, "south")
  Assert.equal(presentation.poseTick, 4, "the phase restarted on the turn tick")

  for tick = 1, 4 do
    walkTick(subject, presentation, "south")
  end
  Assert.equal(subject.fieldZ, 5, "the south tile committed")
  Assert.equal(presentation.poseTick, 8)
end

return { tests = T }
