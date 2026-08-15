-- The player-data validation context for fixtures that save or restore field
-- saves outside the production runtime: the generated field font resolves
-- the demo profile name "GOLD" (real compiled codes) and the imported frame
-- set contains the demo frame, mirroring the runtime injection.
local PlayerDataContext = {}

function PlayerDataContext.new()
  return {
    charmap = { G = 305, O = 313, L = 310, D = 302 },
    frameIndexes = { [0] = true },
  }
end

return PlayerDataContext
