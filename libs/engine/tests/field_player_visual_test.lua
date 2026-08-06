-- The player visual adapter must read FieldPlayer and never write it: pose from
-- motion, facing from the player, interpolated world position from the shared
-- render position, and a deterministic clock that only advances mid-step.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldActorFixture = require("tests.support.FieldActorFixture")
local FieldPlayerVisual = require("libs.engine.src.FieldPlayerVisual")

local T = {}

-- A FieldPlayer-shaped stub: the adapter must depend only on this surface.
local function player()
  return {
    facing = "south", motion = "idle",
    worldX = 2, worldY = 0.5, worldZ = 3,
    previousWorldX = 1, previousWorldY = 0.5, previousWorldZ = 3,
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

local function visual(subject)
  return FieldPlayerVisual.new({
    player = subject, spriteId = 0, visualDef = FieldActorFixture.visual(0),
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
  presentation:setAvatar(97, FieldActorFixture.visual(97, { frameCount = 2 }))
  Assert.equal(presentation.spriteId, 97)
  Assert.equal(presentation.poseTick, 0, "a shorter atlas must not be indexed by the old clock")
end

function T.rejects_an_avatar_without_a_compiled_visual()
  local subject = player()
  local err = Assert.throws(function()
    FieldPlayerVisual.new({ player = subject, spriteId = 0 })
  end)
  Assert.isTrue(Errors.is(err) and err.code == "PLAYER_AVATAR_INVALID",
    "expected PLAYER_AVATAR_INVALID, got " .. tostring(err))
end

return T
