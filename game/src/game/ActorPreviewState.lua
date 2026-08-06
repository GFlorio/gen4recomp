-- Developer preview grid for compiled field-actor visuals. It draws every
-- compiled sprite in all four directions, animating the walk pose off the same
-- fixed 60 Hz tick the field runtime uses, so a frame-order, palette,
-- transparency, or east/west-mirroring defect is visible without booting a map.
-- It is a diagnostic surface only: it owns no field simulation and no actor
-- model, and it acquires and releases through FieldActorAssetProvider exactly
-- like the runtime does.

local CacheFs = require("libs.rom.src.CacheFs")
local Errors = require("libs.rom.src.Errors")
local FieldActorAssetProvider = require("libs.engine.src.FieldActorAssetProvider")

local ActorPreviewState = {}
ActorPreviewState.__index = ActorPreviewState

local FIXED_DT = 1 / 60
local DIRECTIONS = { "north", "south", "west", "east" }
local SCALE = 2
local CELL = 32 * SCALE + 8
local MARGIN = 16
local LABEL_WIDTH = 72

function ActorPreviewState.new(versionId)
  local self = setmetatable({
    versionId = versionId,
    tick = 0,
    accumulator = 0,
    paused = false,
    scroll = 0,
    entries = {},
  }, ActorPreviewState)

  local ok, err = pcall(function()
    self.provider = FieldActorAssetProvider.new(CacheFs.forVersion(versionId))
    for _, spriteId in ipairs(self.provider:index().spriteIds) do
      self.entries[#self.entries + 1] = self.provider:acquire(spriteId)
    end
  end)
  if not ok then self.errorText = Errors.format(err) end
  return self
end

function ActorPreviewState:update(dt)
  if self.errorText then return self:_maybeCaptureAndQuit() end
  self.accumulator = self.accumulator + math.min(dt, 0.25)
  while self.accumulator >= FIXED_DT do
    self.accumulator = self.accumulator - FIXED_DT
    if not self.paused then self.tick = self.tick + 1 end
  end
  self:_maybeCaptureAndQuit()
end

-- Select the displayed frame of a looping pose from the fixed tick, exactly as
-- the runtime pose clock will: walk the per-frame durations the compiler
-- recovered rather than assuming a uniform frame length.
local function frameIndexAt(pose, tick)
  local total = pose.durationTicks
  local position = pose.loop and (tick % total) or math.min(tick, total - 1)
  for _, frame in ipairs(pose.frames) do
    if position < frame.ticks then return frame.frameIndex end
    position = position - frame.ticks
  end
  return pose.frames[#pose.frames].frameIndex
end

ActorPreviewState.frameIndexAt = frameIndexAt

function ActorPreviewState:draw()
  love.graphics.setColor(1, 1, 1)
  if self.errorText then
    love.graphics.print("actor preview unavailable: " .. self.errorText, MARGIN, MARGIN)
    return
  end

  love.graphics.print(string.format(
    "%s  %d sprites  tick %d  [space] pause  [up/down] scroll  [esc] quit"
      .. "   columns: idle then walk, N S W E",
    self.versionId, #self.entries, self.tick), MARGIN, MARGIN)

  local y = MARGIN + 24 - self.scroll * (CELL + 4)
  for _, entry in ipairs(self.entries) do
    local visual = entry.visual
    love.graphics.setColor(0.7, 0.75, 0.85)
    love.graphics.print(string.format("%d", visual.spriteId), MARGIN, y + CELL / 2 - 6)
    love.graphics.setColor(1, 1, 1)
    local x = MARGIN + LABEL_WIDTH
    for _, direction in ipairs(DIRECTIONS) do
      local pose = visual.directions[direction]
      for _, which in ipairs({ pose.idle, pose.walk }) do
        local index = frameIndexAt(which, self.tick)
        love.graphics.draw(entry.image, entry.quads[index], x, y, 0, SCALE, SCALE)
        -- Ground line at the bottom-center pivot, so foot contact is checkable.
        love.graphics.setColor(0.3, 0.9, 0.4, 0.6)
        love.graphics.line(x, y + 32 * SCALE, x + 32 * SCALE, y + 32 * SCALE)
        love.graphics.setColor(1, 1, 1)
        x = x + CELL
      end
      x = x + 8
    end
    y = y + CELL + 4
  end
end

function ActorPreviewState:keypressed(key)
  if key == "escape" then return love.event.quit(0) end
  if key == "space" then self.paused = not self.paused end
  if key == "down" then self.scroll = math.min(self.scroll + 1, #self.entries - 1) end
  if key == "up" then self.scroll = math.max(self.scroll - 1, 0) end
end

-- Env-gated render smoke, matching the map diagnostic: capture one warmed frame
-- to a save-dir-relative path and quit.
function ActorPreviewState:_maybeCaptureAndQuit()
  local path = os.getenv("G4RECOMP_SHOT")
  if not path then return end
  self._frames = (self._frames or 0) + 1
  if self._frames == 8 then
    love.graphics.captureScreenshot(path)
  elseif self._frames >= 9 then
    love.event.quit(self.errorText and 1 or 0)
  end
end

function ActorPreviewState:quit()
  if not self.provider then return end
  for _, entry in ipairs(self.entries) do self.provider:release(entry.spriteId) end
  self.provider:dispose()
end

return ActorPreviewState
