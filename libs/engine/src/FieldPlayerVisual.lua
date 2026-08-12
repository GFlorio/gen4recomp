-- Presents the player with ROM-derived field graphics without taking any
-- movement authority from FieldPlayer.
--
-- FieldPlayer stays the only owner of the player's tile, surface, facing, and
-- step timing; this adapter reads that state, keeps the deterministic pose clock
-- the original advances once per field update while walking, and emits the same
-- ActorDrawRecord shape the object actors emit. The clock represents continuous
-- locomotion: it carries the gait phase across tile boundaries and resets only
-- when the player stops or changes facing, matching the original range-based
-- timeline. Its interpolated world position comes from
-- FieldPlayer:renderPosition, so the player and the camera continue to consume
-- one continuous position.
--
-- Pure domain module: no love dependency and no resource ownership. The caller
-- acquires the avatar's visual from FieldActorAssetProvider and hands it in.

local Errors = require("libs.errors.src.Errors")

---@class FieldPlayerVisual
---@field actorId string
---@field player FieldPlayer
---@field spriteId integer?
---@field pose string
---@field poseTick integer
local FieldPlayerVisual = {}
FieldPlayerVisual.__index = FieldPlayerVisual

FieldPlayerVisual.ACTOR_ID = "field:player"

function FieldPlayerVisual.new(opts)
  assert(type(opts) == "table" and opts.player, "FieldPlayerVisual requires a FieldPlayer")
  local self = setmetatable({
    actorId = FieldPlayerVisual.ACTOR_ID,
    player = opts.player,
    spriteId = nil,
    pose = "idle",
    poseTick = 0,
    lastFacing = opts.player.facing,
  }, FieldPlayerVisual)
  self:setAvatar(opts.spriteId)
  return self
end

-- Switch which compiled graphic presents the player. The pose clock restarts so
-- a swap cannot display a frame index the new atlas does not have.
function FieldPlayerVisual:setAvatar(spriteId)
  if type(spriteId) ~= "number" then
    Errors.raise("PLAYER_AVATAR_INVALID", "the player avatar requires a compiled spriteId", { spriteId = spriteId })
  end
  self.spriteId = spriteId
  self.poseTick = 0
end

-- Called once per fixed simulation tick with `walkingAtTickStart`, whether the
-- player was mid-step when the tick began. The animation clock advances on any
-- tick that touches walking -- including the commit tick that arrives at a
-- tile, which is why the caller captures the state before advancing the player
-- -- so the gait phase carries across tile boundaries. It resets only when the
-- player stops (the first genuinely idle tick) or changes facing, matching the
-- original timeline: a standing actor holds the first frame of its facing
-- range, and a turn starts the new range at its first frame.
function FieldPlayerVisual:updateFixed(walkingAtTickStart)
  local walking = walkingAtTickStart == true or self.player.motion == "walking"

  local facingChanged = self.lastFacing ~= self.player.facing
  if facingChanged then
    self.poseTick = 0
  end
  self.lastFacing = self.player.facing

  if walking then
    self.pose = "walk"
    self.poseTick = self.poseTick + 1
  else
    self.pose = "idle"
    self.poseTick = 0
  end
end

-- `alpha` is the render interpolation factor of the current fixed step.
function FieldPlayerVisual:drawRecord(alpha)
  local point = self.player:renderPosition(alpha)
  return {
    actorId = self.actorId,
    spriteId = self.spriteId,
    world = { x = point.x, y = point.y, z = point.z },
    facing = self.player.facing,
    pose = self.pose,
    poseTick = self.poseTick,
    visible = true,
  }
end

return FieldPlayerVisual
