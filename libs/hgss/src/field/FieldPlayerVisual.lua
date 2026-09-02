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
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

---@class FieldPlayerVisual
---@field actorId string
---@field player FieldPlayer
---@field spriteId integer?
---@field pose string
---@field poseTick integer
---@field _drawRecord table
local FieldPlayerVisual = {}
FieldPlayerVisual.__index = FieldPlayerVisual

FieldPlayerVisual.ACTOR_ID = "field:player"

function FieldPlayerVisual.new(opts)
  assert(type(opts) == "table" and opts.player, "FieldPlayerVisual requires a FieldPlayer")
  assert(
    type(opts.player.presentationState) == "function" and type(opts.player.clearGesturePresentation) == "function",
    "FieldPlayerVisual requires presentationState and clearGesturePresentation"
  )
  local self = setmetatable({
    actorId = FieldPlayerVisual.ACTOR_ID,
    player = opts.player,
    spriteId = nil,
    pose = "idle",
    poseTick = 0,
    lastFacing = opts.player.facing,
    _drawRecord = { world = {} },
  }, FieldPlayerVisual)
  self:setAvatar(opts.spriteId)
  return self
end

-- Switch which compiled graphic presents the player. The pose clock restarts so
-- a swap cannot display a frame index the new atlas does not have.
function FieldPlayerVisual:setAvatar(spriteId)
  if type(spriteId) ~= "number" then
    Errors.raise(
      FieldErrors.PLAYER_AVATAR_INVALID,
      "the player avatar requires a compiled spriteId",
      { spriteId = spriteId }
    )
  end
  self.player:clearGesturePresentation()
  self.spriteId = spriteId
  self.poseTick = 0
end

-- Called once per fixed simulation tick with `locomotionAtTickStart`, whether the
-- player was locomoting when the tick began. The animation clock advances on any
-- tick that touches locomotion -- including the commit tick that arrives at a
-- tile, which is why the caller captures the state before advancing the player
-- so the gait phase carries across tile boundaries. It resets only when the
-- player stops (the first genuinely idle tick) or changes facing, matching the
-- original timeline: a standing actor holds the first frame of its facing
-- range, and a turn starts the new range at its first frame.
function FieldPlayerVisual:updateFixed(locomotionAtTickStart)
  local snapshot = self.player:presentationState()
  local walking = not self.player.animationPaused
    and (locomotionAtTickStart == true or snapshot.locomotionActive == true)

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

-- Stop locomotion presentation at an explicit ownership handoff. This does
-- not alter the player's logical or render position.
function FieldPlayerVisual:settle()
  self.pose = "idle"
  self.poseTick = 0
  self.lastFacing = self.player.facing
end

function FieldPlayerVisual:status()
  return { pose = self.pose, poseTick = self.poseTick }
end

-- `alpha` is the render interpolation factor of the current fixed step.
function FieldPlayerVisual:drawRecord(alpha)
  local point = self.player:renderPosition(alpha)
  local snapshot = self.player:presentationState()
  local record = self._drawRecord
  local gestureOffsetY = snapshot.gestureOffsetY or 0
  record.actorId = self.actorId
  record.spriteId = self.spriteId
  record.world.x = point.x
  record.world.y = point.y + gestureOffsetY
  record.world.z = point.z
  record.facing = self.player.facing
  record.pose = self.pose
  record.poseTick = self.poseTick
  record.gesturePose = snapshot.gesturePose
  record.gestureTick = snapshot.gestureTick
  record.visible = true
  return record
end

return FieldPlayerVisual
