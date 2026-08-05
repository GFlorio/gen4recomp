-- Owns the deterministic fade/load/swap/fade lifecycle for field warps. Map
-- projection and actor state swap atomically through an injected callback only
-- while the viewport is fully black.

local WarpSystem = require("libs.engine.src.WarpSystem")

local FieldTransition = {}
FieldTransition.__index = FieldTransition

FieldTransition.FADE_OUT_TICKS = 12
FieldTransition.FADE_IN_TICKS = 12

function FieldTransition.new(options)
  assert(options and options.loader and options.loader.protectMap, "field transition loader required")
  assert(type(options.swap) == "function", "field transition swap callback required")
  local fadeOutTicks = options.fadeOutTicks or FieldTransition.FADE_OUT_TICKS
  local fadeInTicks = options.fadeInTicks or FieldTransition.FADE_IN_TICKS
  assert(fadeOutTicks > 0 and fadeOutTicks == math.floor(fadeOutTicks), "positive fade-out ticks required")
  assert(fadeInTicks > 0 and fadeInTicks == math.floor(fadeInTicks), "positive fade-in ticks required")
  return setmetatable({
    loader = options.loader,
    resolveDestination = options.resolveDestination or WarpSystem.resolveDestination,
    swap = options.swap,
    fadeOutTicks = fadeOutTicks,
    fadeInTicks = fadeInTicks,
    phase = "idle",
    locked = false,
    fadeAlpha = 0,
  }, FieldTransition)
end

function FieldTransition:start(sourceMap, warp, facing)
  assert(self.phase == "idle", "field transition already active")
  assert(sourceMap and warp and facing, "transition source, warp, and facing required")
  self.sourceMap = sourceMap
  self.sourceWarp = warp
  self.facing = facing
  self.progressTicks = 0
  self.resolution = nil
  self.error = nil
  self.completed = nil
  self.phase = "fade_out"
  self.locked = true
  self.fadeAlpha = 0
  self.loader:protectMap(sourceMap.mapId, true)
end

function FieldTransition:_fail(err)
  self.error = err
  self.phase = "error"
  self.locked = false
  self.fadeAlpha = 0
  self.loader:protectMap(self.sourceMap.mapId, true)
end

function FieldTransition:updateFixed()
  if self.phase == "idle" or self.phase == "error" then return end
  if self.phase == "fade_out" then
    self.progressTicks = self.progressTicks + 1
    self.fadeAlpha = self.progressTicks / self.fadeOutTicks
    if self.progressTicks >= self.fadeOutTicks then
      self.fadeAlpha = 1
      self.phase = "load_destination"
    end
    return
  end
  if self.phase == "load_destination" then
    local ok, result = pcall(self.resolveDestination,
      self.loader, self.sourceMap, self.sourceWarp)
    if not ok then return self:_fail(result) end
    self.resolution = result
    self.suppression = result.suppression
    self.loader:protectMap(result.destinationMap.mapId, true)
    self.phase = "swap_map"
    return
  end
  if self.phase == "swap_map" then
    assert(self.fadeAlpha == 1, "map swap must occur while fully black")
    self.swap(self.resolution, self.facing)
    self.progressTicks = 0
    self.phase = "fade_in"
    return
  end
  assert(self.phase == "fade_in", "unknown field transition phase")
  self.progressTicks = self.progressTicks + 1
  self.fadeAlpha = 1 - self.progressTicks / self.fadeInTicks
  if self.progressTicks < self.fadeInTicks then return end
  self.fadeAlpha = 0
  self.phase = "idle"
  self.locked = false
  self.completed = {
    sourceMapId = self.sourceMap.mapId,
    destinationMapId = self.resolution.destinationMap.mapId,
    sourceWarpId = self.sourceWarp.index,
  }
  if self.sourceMap.mapId ~= self.resolution.destinationMap.mapId then
    if self.loader.protectCells then self.loader:protectCells(self.sourceMap.mapId, {}) end
    self.loader:protectMap(self.sourceMap.mapId, false)
  end
  self.sourceMap, self.sourceWarp, self.resolution = nil, nil, nil
end

function FieldTransition:consumeCompleted()
  local completed = self.completed
  self.completed = nil
  return completed
end

return FieldTransition
