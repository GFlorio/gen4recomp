-- Proof-of-life state shown after a successful import. It reaches the
-- HGSS data foundation using only the RomFs public API: open the version dump,
-- open the map_matrices NARC, read member 0, and decode it. All figures are
-- gathered once at construction; draw() only renders. A failure is captured as
-- text rather than crashing the window.

local RomFs = require("src.core.RomFs")
local MapMatrix = require("src.data.MapMatrix")

local DiagnosticState = {}
DiagnosticState.__index = DiagnosticState

function DiagnosticState.new(versionId)
  local self = setmetatable({ versionId = versionId, lines = {}, errorText = nil }, DiagnosticState)
  self:_load()
  return self
end

function DiagnosticState:_load()
  local ok, err = pcall(function()
    local romFs = assert(RomFs.open(self.versionId))
    local meta = romFs:metadata()
    local stats = romFs:stats()
    local matrices = assert(romFs:openNarc("map_matrices"))
    local firstMember = assert(matrices:readMember(0))
    local matrix = assert(MapMatrix.decode(firstMember, 0))

    self.lines = {
      "Active version:        " .. romFs:version(),
      "ROM SHA-1:             " .. meta.sha1,
      "Game code:             " .. meta.gameCode,
      "Total FAT files:       " .. stats.fileCount,
      "Named NitroFS files:   " .. stats.namedFileCount,
      "Overlay files:         " .. stats.overlayFileCount,
      "Unmapped files:        " .. stats.unmappedFileCount,
      "Total dumped bytes:    " .. stats.totalFileBytes,
      "Resolved NARC aliases: " .. stats.resolvedNarcCount,
      "map_matrices members:  " .. matrices:memberCount(),
      string.format("Matrix[0]:             name=%q  %dx%d  model cells=%d",
        matrix.name, matrix.width, matrix.height, matrix.width * matrix.height),
    }
    romFs:close()
  end)
  if not ok then
    self.errorText = tostring(err)
  end
end

function DiagnosticState:draw()
  local lg = love.graphics
  local x, y = 24, 24
  lg.setColor(1, 1, 1)
  lg.print("g4recomp — data diagnostic", x, y)
  if self.errorText then
    lg.setColor(1, 0.5, 0.5)
    lg.print("Diagnostic failed:", x, y + 32)
    lg.print(self.errorText, x, y + 52)
    return
  end
  lg.setColor(0.85, 0.9, 0.95)
  for i, line in ipairs(self.lines) do
    lg.print(line, x, y + 20 + i * 20)
  end
end

function DiagnosticState:update(dt) end

function DiagnosticState:keypressed(key)
  if key == "escape" then love.event.quit(0) end
end

return DiagnosticState
