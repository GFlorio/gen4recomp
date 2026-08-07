---@diagnostic disable: duplicate-set-field
-- LÖVE configuration for the docs generator CLI. Always windowless, like the
-- romdump CLI: it renders no graphics, plays no audio, and exits immediately.

function love.conf(t)
  t.identity = "g4recomp"
  t.version = "11.5"
  t.modules.physics = false
  t.modules.window = false
  t.modules.graphics = false
  t.modules.audio = false
  t.modules.sound = false
  t.modules.joystick = false
  t.modules.touch = false
end
