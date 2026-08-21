-- GameAudio: the reusable production composition for semantic game audio. It
-- owns the generated asset provider, shared mixer/player, standard cry
-- service, GameSound facade, and optional LÖVE output sink. Field audio adds
-- map policy around this record; non-field states can consume the same sound
-- engine without constructing field collaborators.

local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local CryPlayer = require("libs.engine.src.audio.CryPlayer")
local GameSound = require("libs.engine.src.audio.GameSound")
local LoveAudioSink = require("game.src.game.audio.LoveAudioSink")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")

local GameAudio = {}

---@class GameAudioComposeOptions
---@field cacheFs CacheFs
---@field outputRate integer
---@field outputHost table?

---@class GameAudioComposition
---@field provider AudioAssetProvider
---@field mixer VoiceMixer
---@field player SequencePlayer
---@field cry CryPlayer
---@field sound GameSound
---@field sink LoveAudioSink|nil

---@param opts GameAudioComposeOptions
---@return GameAudioComposition
function GameAudio.compose(opts)
  assert(opts and opts.cacheFs and opts.outputRate, "GameAudio.compose requires cacheFs and outputRate")

  local provider = AudioAssetProvider.new(opts.cacheFs)
  local mixer = VoiceMixer.new({ sampleRate = opts.outputRate })
  local player = SequencePlayer.new({
    sampleRate = opts.outputRate,
    mixer = mixer,
    provider = provider,
  })

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
        renderer = player,
        sampleRate = opts.outputRate,
      })
    end

    local cry = CryPlayer.new({ player = player, provider = provider })
    local sound = GameSound.new({
      provider = provider,
      player = player,
      cry = cry,
    })
    return {
      provider = provider,
      mixer = mixer,
      player = player,
      cry = cry,
      sound = sound,
      sink = sink,
    }
  end)

  if not ok then
    if sink ~= nil then
      pcall(sink.release, sink)
    end
    error(composition, 0)
  end
  return composition
end

return GameAudio
