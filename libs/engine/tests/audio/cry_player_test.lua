-- CryPlayer contract: the production cry data path plays the referenced
-- cry as a short SE-style stand-in sequence through the engine audio
-- player on the cry slot, and reports finished once the slot's sequence
-- has ended. GameSound's injectable cry boundary is pinned by
-- game_sound_test; this suite pins the subsystem the production
-- composition injects.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local AudioBank = require("libs.assets.src.AudioBank")
local AudioSequence = require("libs.assets.src.AudioSequence")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local CryPlayer = require("libs.engine.src.audio.CryPlayer")

local T = {}

---@class CryPlayerTest.Player : CryPlayer.Player
---@field play fun(self: CryPlayerTest.Player, handle: table, sequence: table, bank: table): boolean
---@field stopSequence fun(self: CryPlayerTest.Player, sequenceId: integer)
---@field render fun(self: CryPlayerTest.Player, frames: integer)
---@field isHandlePlaying fun(self: CryPlayerTest.Player, handle: table): boolean

local SAMPLE_RATE = 48000

-- The default fanfare fixture runs on player 3, the cry slot, so the
-- player index carries a player-3 record for the stand-in to resolve.
local function defaultSequences()
  return {
    [0] = AudioFixture.sequence(0, "SEQ_TEST_BGM", 12, 1),
    [1] = AudioFixture.sequence(1, "SEQ_TEST_FANFARE", 12, 3, {
      entry = 1,
      initialTrackMask = 0x0001,
      instructions = {
        { op = "program", program = 1 },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      },
    }),
  }
end

local function newCryPlayer(opts)
  opts = opts or {}
  local bundle = AudioFixture.bundle()
  local indexSequences, indexPlayers, sequenceBySymbol = {}, {}, {}
  for id, sequence in pairs(defaultSequences()) do
    indexSequences[id] = {
      id = id,
      symbol = sequence.symbol,
      bankId = sequence.bankId,
      playerId = sequence.player.id,
    }
    sequenceBySymbol[sequence.symbol] = id
    if indexPlayers[sequence.player.id] == nil then
      indexPlayers[sequence.player.id] = {
        id = sequence.player.id,
        maxSequences = opts.maxSequences or 16,
        channelMask = 0xFFFF,
      }
    end
  end
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.sequenceBySymbol = sequenceBySymbol
  local provider = AudioAssetProvider.new(AudioFixture.readyCache(bundle))
  local player = SequencePlayer.new({
    sampleRate = SAMPLE_RATE,
    mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE }),
    provider = provider,
    observer = opts.observer,
  }) --[[@as CryPlayerTest.Player]]
  return CryPlayer.new({ player = player }), player, provider
end

function T.cry_passes_a_valid_current_schema_sequence_to_the_engine_player()
  local capturedSequence
  local capturedBank
  local player = {
    _sampleRate = SAMPLE_RATE,
    _mixer = {},
    _provider = {},
    _logicalPlayers = {},
    _seqPlayers = {},
    _freeSeqPlayerSlots = {},
    _trackPool = {},
    _handles = {},
    _handleAttachments = {},
    _soundPhase = 0,
    createHandle = function()
      return {}
    end,
    play = function()
      return true
    end,
    playSynthetic = function(_, _, sequence, bank)
      capturedSequence = sequence
      capturedBank = bank
      return true
    end,
    render = function() end,
    stop = function() end,
    isPlayerPlaying = function()
      return false
    end,
    isPlaying = function()
      return false
    end,
    setHandleFader = function() end,
    pauseHandle = function() end,
    resumeHandle = function() end,
    stopHandle = function() end,
    releaseHandle = function() end,
    isHandlePlaying = function()
      return false
    end,
    stopSequence = function() end,
  } --[[@as CryPlayerTest.Player]]
  local cry = CryPlayer.new({ player = player })

  cry:play(25, 0)

  Assert.isTrue(AudioSequence.validate(capturedSequence))
  Assert.isTrue(AudioBank.validate(capturedBank))
  Assert.equal(0x0001, capturedSequence.program.initialTrackMask)
  Assert.equal(64, capturedSequence.player.channelPriority)
end

function T.stopping_ordinary_sequence_2000_does_not_stop_the_cry_standin()
  local cry, player, provider = newCryPlayer()
  local handle = player:createHandle()
  local sequence = AudioFixture.sequence(2000, "SEQ_TEST_2000", 12, 1)
  player:play(handle, sequence, provider:bank(12))

  cry:play(25, 0)
  player:stopSequence(2000)

  Assert.isFalse(player:isHandlePlaying(handle), "the ordinary sequence is stopped")
  Assert.isFalse(cry:isFinished(), "the cry stand-in is not an ordinary sequence")
end

function T.play_starts_the_cry_slot_and_finishes_when_the_sequence_ends()
  local cry, player = newCryPlayer()
  Assert.isTrue(cry:isFinished(), "an idle cry slot is finished")
  cry:play(25, 0)
  Assert.isFalse(cry:isFinished(), "the cry is active once started")
  Assert.isTrue(player:isPlayerPlaying(3), "the stand-in plays on the cry slot")
  -- The two-note stand-in ends within the rendered window.
  player:render(4000)
  Assert.isTrue(cry:isFinished(), "the stand-in ends and frees the cry slot")
  Assert.isFalse(player:isPlayerPlaying(3))
end

function T.play_replaces_an_active_cry_without_a_stale_wait()
  local cry, player = newCryPlayer()
  cry:play(25, 0)
  player:render(200)
  cry:play(133, 0)
  Assert.isFalse(cry:isFinished(), "the replacement cry is active")
  player:render(4000)
  Assert.isTrue(cry:isFinished(), "the replacement ends")
end

function T.repeated_cries_explicitly_stop_the_previous_private_attachment()
  local retirements = {}
  local cry, player = newCryPlayer({
    maxSequences = 2,
    observer = {
      onSequenceRetirement = function(_, event)
        retirements[#retirements + 1] = event
      end,
    },
  })
  local stopCalls = 0
  local stopHandle = player.stopHandle
  rawset(player, "stopHandle", function(self, handle)
    stopCalls = stopCalls + 1
    return stopHandle(self, handle)
  end)
  cry:play(25, 0)
  player:render(250)
  stopCalls = 0
  cry:play(133, 0)
  Assert.equal(stopCalls, 1, "cry replacement explicitly stops the private attachment")
  Assert.equal(#retirements, 1, "a second cry retires the previous private attachment")
  Assert.isFalse(cry:isFinished(), "the replacement cry remains active")
end

function T.construction_requires_the_engine_player()
  local ok = pcall(CryPlayer.new, {})
  Assert.isFalse(ok, "a cry player without the engine player is a composition fault")
end

return { tests = T }
