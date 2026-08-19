-- FieldAudio: the production field-audio composition. One plain function
-- wires the engine audio stack (AudioAssetProvider -> VoiceMixer ->
-- SequencePlayer -> GameSound -> FieldAudioController), the cry boundary
-- (CryPlayer over the composed player), and the LÖVE output sink from the
-- runtime's inputs; FieldRuntime consumes only the composed service and sink
-- and never constructs an audio collaborator itself. This module is wiring,
-- not a stateful audio runtime: compose carries no instance state.

local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local CryPlayer = require("libs.engine.src.audio.CryPlayer")
local FieldAudioController = require("libs.engine.src.audio.FieldAudioController")
local GameSound = require("libs.engine.src.audio.GameSound")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local LoveAudioSink = require("game.src.game.audio.LoveAudioSink")

local FieldAudio = {}

---@param opts { cacheFs: table, outputRate: integer, eventState: any, fieldPosition: fun():integer,integer, dayNight: fun(): "day"|"night", fieldDataForMap: fun(mapIdOrSymbol: integer|string): any, outputHost: table|nil }
---@return { service: FieldAudioController, sink: LoveAudioSink|nil }
function FieldAudio.compose(opts)
  assert(
    opts
      and opts.cacheFs
      and opts.outputRate
      and opts.eventState
      and opts.fieldPosition
      and opts.dayNight
      and opts.fieldDataForMap,
    "FieldAudio.compose requires cacheFs, outputRate, eventState, fieldPosition, dayNight, and fieldDataForMap"
  )
  ---@cast opts +{ outputHost: table|nil }
  local provider = AudioAssetProvider.new(opts.cacheFs)
  local mixer = VoiceMixer.new({ sampleRate = opts.outputRate })
  local player = SequencePlayer.new({
    sampleRate = opts.outputRate,
    mixer = mixer,
    provider = provider,
  })
  -- The LÖVE output sink is built over the injected audio-output host
  -- boundary (acceptance fakes it); production defaults to the
  -- love.audio + love.sound namespaces, and a host with no audio module
  -- has no sink to pump. The sink receives the SequencePlayer as its
  -- renderer.
  local sink
  local outputHost = opts.outputHost
  if outputHost == nil and love.audio ~= nil then
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
  local sound = GameSound.new({
    provider = provider,
    player = player,
    cry = CryPlayer.new({ player = player }),
  })
  return {
    service = FieldAudioController.new({
      sound = sound,
      provider = provider,
      eventState = opts.eventState,
      fieldPosition = opts.fieldPosition,
      dayNight = opts.dayNight,
      fieldDataForMap = opts.fieldDataForMap,
    }),
    sink = sink,
  }
end

return FieldAudio
