-- FieldAudio: the production field-audio composition. One plain function
-- wires the engine audio stack (AudioAssetProvider -> VoiceMixer ->
-- SequencePlayer -> GameSound -> FieldAudioController), the cry boundary
-- (CryPlayer over the composed player), and the LÖVE output sink from the
-- runtime's inputs; FieldRuntime consumes only the composed service and sink
-- and never constructs an audio collaborator itself. This module is wiring,
-- not a stateful audio runtime: compose carries no instance state.

local FieldAudioController = require("libs.engine.src.audio.FieldAudioController")
local GameAudio = require("game.src.game.audio.GameAudio")

local FieldAudio = {}

---@class FieldAudioComposeOptions
---@field cacheFs table
---@field outputRate integer
---@field eventState any
---@field fieldPosition fun(): integer, integer
---@field dayNight fun(): "day"|"night"
---@field fieldDataForMap fun(mapIdOrSymbol: integer|string): any
---@field outputHost table|nil

---@param opts FieldAudioComposeOptions
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
  local core = GameAudio.compose(opts --[[@as GameAudioComposeOptions]])
  local ok, fieldService = pcall(function()
    return FieldAudioController.new({
      sound = core.sound,
      provider = core.provider,
      eventState = opts.eventState,
      fieldPosition = opts.fieldPosition,
      dayNight = opts.dayNight,
      fieldDataForMap = opts.fieldDataForMap,
    })
  end)
  if not ok then
    if core.sink ~= nil then
      pcall(core.sink.release, core.sink)
    end
    error(fieldService, 0)
  end
  return { service = fieldService, sink = core.sink }
end

return FieldAudio
