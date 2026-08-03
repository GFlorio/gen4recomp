-- Top-level state dispatcher. In this milestone it only shows the import
-- instruction screen; importer, diagnostics, and version selection states are
-- wired in later epics (spec §15).

local App = {}

local function saveDir()
  return love.filesystem.getSaveDirectory()
end

function App.load(flags)
  App.flags = flags or {}
  love.graphics.setBackgroundColor(0.08, 0.09, 0.12)
end

function App.update(dt) end

function App.draw()
  local lg = love.graphics
  local x, y = 24, 24
  lg.setColor(1, 1, 1)
  lg.print("g4recomp", x, y)
  lg.print("HeartGold / SoulSilver ROM importer (data diagnostic milestone)", x, y + 24)
  lg.print("Drop a .nds file onto this window to import it.", x, y + 60)
  lg.setColor(0.7, 0.7, 0.75)
  lg.print("Private cache will be written under:", x, y + 96)
  lg.print(saveDir(), x, y + 116)
end

function App.filedropped(file)
  -- Import wiring arrives in Epic 8.
end

function App.keypressed(key)
  if key == "escape" then love.event.quit(0) end
end

return App
