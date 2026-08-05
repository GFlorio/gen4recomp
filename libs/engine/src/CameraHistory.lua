-- CameraHistory reproduces the field camera's Y-only circular delta history
-- recovered in pret/pokeheartgold's field overlay 1 assembly. HGSS initializes
-- a seven-entry ring at write index six: the ring is live while priming, then
-- emits the entry after the current write, six ticks old.

local CameraHistory = {}
CameraHistory.__index = CameraHistory

function CameraHistory.new(count, initialWriteIndex)
  count = count or 7
  initialWriteIndex = initialWriteIndex or (count - 1)
  assert(count > 0 and count % 1 == 0, "history count must be a positive integer")
  assert(initialWriteIndex >= 0 and initialWriteIndex < count, "initial write index is out of bounds")
  return setmetatable({
    count = count,
    initialWriteIndex = initialWriteIndex,
    writeIndex = initialWriteIndex,
    values = {},
    writes = 0,
  }, CameraHistory)
end

function CameraHistory:push(value)
  assert(type(value) == "number", "history value must be numeric")
  self.writeIndex = (self.writeIndex + 1) % self.count
  self.values[self.writeIndex] = value
  self.writes = self.writes + 1
  if self.writes <= self.count then return value end
  return self.values[(self.writeIndex + 1) % self.count]
end

function CameraHistory:reset()
  self.writeIndex = self.initialWriteIndex
  self.values = {}
  self.writes = 0
end

return CameraHistory
