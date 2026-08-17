-- CryPlayer contract: the production cry data path plays the referenced
-- cry as a short SE-style stand-in sequence through the engine audio
-- player on the cry slot, and reports finished once the slot's sequence
-- has ended. GameSound's injectable cry boundary is pinned by
-- game_sound_test; this suite pins the subsystem the production
-- composition injects.

local Assert = require("tests.support.Assert")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local CryPlayer = require("libs.engine.src.audio.CryPlayer")

local T = {}

local SAMPLE_RATE = 48000

local function voice(key)
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = 0,
  }
end

-- The default fanfare fixture runs on player 3, the cry slot, so the
-- player index carries a player-3 record for the stand-in to resolve.
local function defaultSequences()
  return {
    [0] = AudioFixture.sequence(0, "SEQ_TEST_BGM", 12, 1),
    [1] = AudioFixture.sequence(1, "SEQ_TEST_FANFARE", 12, 3, {
      entry = 1,
      instructions = {
        { op = "program", program = 1 },
        { op = "note", key = 60, velocity = 127, duration = 1 },
        { op = "end" },
      },
    }),
  }
end

local function newCryPlayer()
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
        maxSequences = 16,
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
  })
  return CryPlayer.new({ player = player }), player
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

function T.construction_requires_the_engine_player()
  local ok = pcall(CryPlayer.new, {})
  Assert.isFalse(ok, "a cry player without the engine player is a composition fault")
end

return { tests = T }
