-- GameAudio: the application-owned composition of the HGSS audio runtime and
-- the optional LÖVE output sink.

local AudioRuntime = require("libs.hgss.src.audio.AudioRuntime")
local LoveAudioSink = require("game.src.audio.LoveAudioSink")

local GameAudio = {}

---@class GameAudioComposeOptions
---@field cacheFs CacheFs
---@field outputRate integer
---@field outputHost table<string, unknown>?
---@field field table<string, unknown>?

---@class GameAudioComposition
---@field sound GameSound
---@field renderer { render: fun(self: table<string, unknown>, frames: integer): integer[] }
---@field fieldService FieldAudioController?
---@field sink LoveAudioSink|nil

---@param opts GameAudioComposeOptions
---@return GameAudioComposition
function GameAudio.compose(opts)
  assert(opts and opts.cacheFs and opts.outputRate, "GameAudio.compose requires cacheFs and outputRate")

  local core = AudioRuntime.compose(opts --[[@as HgssAudioRuntimeOptions]])

  local sink
  local ok, composition = pcall(function()
    local outputHost = opts.outputHost
    if outputHost == nil and love ~= nil and love.audio ~= nil then
      outputHost = { audio = love.audio, sound = love.sound }
    end
    if outputHost ~= nil then
      sink = LoveAudioSink.new({
        audio = outputHost.audio,
        sound = outputHost.sound,
        renderer = core.renderer,
        sampleRate = opts.outputRate,
      })
    end

    assert(core.sound and core.renderer, "AudioRuntime.compose must return a usable audio composition")

    return {
      sound = core.sound,
      renderer = core.renderer,
      fieldService = core.fieldService,
      sink = sink,
    }
  end)

  if not ok then
    if sink ~= nil then
      pcall(sink.release, sink)
    end
    error(composition, 0)
  end
  ---@cast composition GameAudioComposition
  return composition
end

return GameAudio
