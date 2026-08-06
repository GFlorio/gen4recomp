-- Presents the player with ROM-derived field graphics without taking any
-- movement authority from FieldPlayer.
--
-- FieldPlayer stays the only owner of the player's tile, surface, facing, and
-- step timing; this adapter reads that state, keeps the deterministic pose clock
-- the original advances once per field update while walking, and emits the same
-- ActorDrawRecord shape the object actors emit. Its interpolated world position
-- comes from FieldPlayer:renderPosition, so the player and the camera continue to
-- consume one continuous position.
--
-- Pure domain module: no love dependency and no resource ownership. The caller
-- acquires the avatar's visual from FieldActorAssetProvider and hands it in.

local Errors = require("libs.rom.src.Errors")

local FieldPlayerVisual = {}
FieldPlayerVisual.__index = FieldPlayerVisual

FieldPlayerVisual.ACTOR_ID = "field:player"

function FieldPlayerVisual.new(opts)
  assert(type(opts) == "table" and opts.player, "FieldPlayerVisual requires a FieldPlayer")
  local self = setmetatable({
    actorId = FieldPlayerVisual.ACTOR_ID,
    player = opts.player,
    spriteId = nil,
    visualDef = nil,
    pose = "idle",
    poseTick = 0,
  }, FieldPlayerVisual)
  self:setAvatar(opts.spriteId, opts.visualDef)
  return self
end

-- Switch which compiled graphic presents the player. The pose clock restarts so
-- a swap cannot display a frame index the new atlas does not have.
function FieldPlayerVisual:setAvatar(spriteId, visualDef)
  if type(spriteId) ~= "number" or type(visualDef) ~= "table" then
    Errors.raise("PLAYER_AVATAR_INVALID",
      "the player avatar requires a compiled spriteId and visual definition",
      { spriteId = spriteId })
  end
  self.spriteId, self.visualDef = spriteId, visualDef
  self.poseTick = 0
end

-- Called once per fixed simulation tick. The animation clock advances only while
-- the player is mid-step, matching the original timeline: a standing actor holds
-- the first frame of its facing range.
function FieldPlayerVisual:updateFixed()
  if self.player.motion == "walking" then
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
    visualDef = self.visualDef,
    world = { x = point.x, y = point.y, z = point.z },
    facing = self.player.facing,
    pose = self.pose,
    poseTick = self.poseTick,
    alpha = 1,
    visible = true,
    interpolation = alpha,
  }
end

return FieldPlayerVisual
