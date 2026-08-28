-- Durable controller state-machine coverage for field music and
-- environmental soundplates. The controller owns base field music
-- identity, persisted override, soundplate selection, donor-bank
-- routing, and map-entry lifecycle against the generated field
-- cache. No ROM is required.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local AudioFixture = require("tests.support.AudioFixture")
local AudioAssetProvider = require("libs.engine.src.audio.AudioAssetProvider")
local VoiceMixer = require("libs.engine.src.audio.VoiceMixer")
local SequencePlayer = require("libs.engine.src.audio.SequencePlayer")
local GameSound = require("libs.engine.src.audio.GameSound")
local FieldAudioController = require("libs.engine.src.audio.FieldAudioController")
local FieldMapDataCache = require("libs.assets.src.FieldMapDataCache")

local T = {}

---@class FieldAudioControllerTest.SequencePlayer : SequencePlayer
---@field playWithBankOverride fun(self: FieldAudioControllerTest.SequencePlayer, handle: table, sequence: table, bank: table): boolean
---@field isPlayerPlaying fun(self: FieldAudioControllerTest.SequencePlayer, playerId: integer): boolean

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected structured error, got " .. tostring(err))
  Assert.equal(err.code, code)
end

local function voice(key)
  return {
    generator = { kind = "sample", sample = key },
    originalKey = 60,
    envelope = { attack = 127, decay = 0, sustain = 127, release = 127 },
    pan = 0,
  }
end

local function bankWithSamples(id, symbol, key)
  return AudioFixture.bank(id, symbol, { key }, {
    [0] = { kind = "direct", voice = voice(key) },
    [1] = { kind = "direct", voice = voice(key) },
  })
end

local SAMPLE_RATE = 48000

---@param opts table
---@return FieldAudioControllerTest.SequencePlayer
local function newSequencePlayer(opts)
  return SequencePlayer.new(opts) --[[@as FieldAudioControllerTest.SequencePlayer]]
end

---@param id integer
---@param symbol string
---@param bankId integer
---@param playerId integer
---@param instructions table[]
---@return AudioFixture.Sequence
local function seq(id, symbol, bankId, playerId, instructions)
  return AudioFixture.sequence(
    id,
    symbol,
    bankId,
    playerId,
    { entry = 1, initialTrackMask = 0x0001, instructions = instructions },
    {
      id = playerId,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    }
  )
end

---@param sequences table<integer, AudioFixture.Sequence>
---@param banks table<integer, AudioFixture.Bank>
---@return AudioAssetProvider
local function providerFor(sequences, banks)
  local bundle = AudioFixture.bundle()
  local indexSequences, indexPlayers, sequenceBySymbol, indexBanks, bankBySymbol = {}, {}, {}, {}, {}
  for id, s in pairs(sequences) do
    indexSequences[id] = { id = id, symbol = s.symbol, bankId = s.bankId, playerId = s.player.id }
    sequenceBySymbol[s.symbol] = id
    if indexPlayers[s.player.id] == nil then
      indexPlayers[s.player.id] = { id = s.player.id, maxSequences = 16, channelMask = 0xFFFF }
    end
  end
  for id, b in pairs(banks) do
    indexBanks[id] = { id = id, symbol = b.symbol }
    bankBySymbol[b.symbol] = id
  end
  bundle.index.sequences = indexSequences
  bundle.index.players = indexPlayers
  bundle.index.banks = indexBanks
  bundle.index.sequenceBySymbol = sequenceBySymbol
  bundle.index.bankBySymbol = bankBySymbol
  bundle.sequences = sequences
  bundle.banks = banks
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  bundle.samples = {
    [keyA] = AudioFixture.pcm16le({ 1000, 2000, 3000, 4000 }),
    [keyB] = AudioFixture.pcm16le({ 5000, 6000 }),
  }
  bundle.sampleMetadata = {
    [keyA] = AudioFixture.sampleMetadata(keyA, { frames = 4 }),
    [keyB] = AudioFixture.sampleMetadata(keyB, { frames = 2 }),
  }
  return AudioAssetProvider.new(AudioFixture.readyCache(bundle) --[[@as CacheFs]])
end

---@param provider AudioAssetProvider
---@param player SequencePlayer
---@return GameSound, table
local function recordingSound(provider, player)
  ---@class RecordingSound : GameSound
  ---@field _spy { moves: table[], stops: table[], fades: table[], plays: table[], playWithBankCalls: table[] }
  ---@diagnostic disable-next-line: missing-fields -- test double wraps real GameSound
  local sound = GameSound.new({ provider = provider, player = player }) --[[@as RecordingSound]]
  local spy = { moves = {}, stops = {}, fades = {}, plays = {}, playWithBankCalls = {} }
  local origPlayMusic = sound.playMusic
  ---@diagnostic disable-next-line: duplicate-set-field -- test spy
  sound.playMusic = function(self, idOrSymbol)
    spy.plays[#spy.plays + 1] = idOrSymbol
    return origPlayMusic(self, idOrSymbol)
  end
  local origMove = sound.moveSequenceVolume
  ---@diagnostic disable-next-line: duplicate-set-field -- test spy
  sound.moveSequenceVolume = function(self, ref, target, duration)
    spy.moves[#spy.moves + 1] = { ref = ref, target = target, duration = duration }
    return origMove(self, ref, target, duration)
  end
  local origStop = sound.stopSequenceWithFade
  ---@diagnostic disable-next-line: duplicate-set-field -- test spy
  sound.stopSequenceWithFade = function(self, ref, duration)
    spy.stops[#spy.stops + 1] = { ref = ref, duration = duration }
    return origStop(self, ref, duration)
  end
  local origFadeOut = sound.fadeMusicOut
  ---@diagnostic disable-next-line: duplicate-set-field -- test spy
  sound.fadeMusicOut = function(self, spec)
    spy.fades[#spy.fades + 1] = spec
    return origFadeOut(self, spec)
  end
  local orig = sound.playWithBankOverride
  ---@diagnostic disable-next-line: duplicate-set-field -- test spy
  sound.playWithBankOverride = function(self, seqRef, bankRef)
    spy.playWithBankCalls[#spy.playWithBankCalls + 1] = { seqRef = seqRef, bankRef = bankRef }
    return orig(self, seqRef, bankRef)
  end
  return sound, spy
end

local function eventState(flags)
  flags = flags or {}
  return {
    isFlagSet = function(_, flagId)
      return flags[flagId] == true
    end,
  }
end

local function fieldDataWithSoundplates(soundplates, music)
  music = music
    or {
      day = "SEQ_GS_T_WAKABA",
      night = "SEQ_GS_T_WAKABA",
      flagOverrides = {},
      traversalOverrides = {},
    }
  return {
    music = music,
    soundplates = soundplates,
    schema = FieldMapDataCache.FIELD_SCHEMA,
    mapId = 111,
    events = { warps = {}, background = {}, objects = {}, coordinates = {} },
  }
end

local function gameplayPlayer(fieldX, fieldZ)
  return {
    fieldX = fieldX,
    fieldZ = fieldZ,
  }
end

local function musicScenario()
  local keyA = AudioFixture.key(1)
  local bgmA =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local bgmB =
    seq(11, "SEQ_GS_UTSUGI_RABO", 12, 1, { { op = "note", key = 62, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgmA, [11] = bgmB }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, player)
  local fdA = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
  )
  fdA.mapId = 111
  local fdB = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_UTSUGI_RABO", night = "SEQ_GS_UTSUGI_RABO", flagOverrides = {}, traversalOverrides = {} }
  )
  fdB.mapId = 112
  local destination = fdB
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return 0, 0
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return destination
    end,
  })
  return controller, sound, spy, fdA, fdB, function(fieldData)
    destination = fieldData
  end
end

function T.same_map_music_entry_preserves_the_running_sequence()
  local controller, sound, spy, fdA, fdB, setDestination = musicScenario()
  fdB.music.day = "SEQ_GS_T_WAKABA"
  fdB.music.night = "SEQ_GS_T_WAKABA"
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.plays = {}
  spy.fades = {}
  setDestination(fdB)
  controller:beginWarp(fdB.mapId)
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = true })
  Assert.equal(#spy.plays, 0, "map entry must not restart the current effective BGM")
  Assert.equal(#spy.fades, 0, "same-BGM map entry must not start a warp fade")
  Assert.equal(sound:currentMusic(), 10)
end

function T.different_map_music_entry_starts_the_destination_once()
  local controller, sound, spy, fdA, fdB = musicScenario()
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.plays = {}
  controller:beginWarp(fdB.mapId)
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = true })
  Assert.equal(#spy.plays, 1, "different destination BGM must start exactly once")
  Assert.equal(spy.plays[1], 11)
  Assert.equal(#spy.fades, 1, "different destination BGM must retain the pre-fade")
  Assert.equal(sound:currentMusic(), 11)
end

function T.clearing_an_override_compares_against_actual_playback()
  local controller, sound, spy, fdA, fdB = musicScenario()
  fdA.music.day = "SEQ_GS_UTSUGI_RABO"
  fdA.music.night = "SEQ_GS_UTSUGI_RABO"
  controller:enterMap({ fieldData = fdA }, { restoredMusicOverride = 10, play = true })
  Assert.equal(sound:currentMusic(), 10)
  spy.plays = {}
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = true })
  Assert.equal(#spy.plays, 1, "clearing an override must start a different effective destination BGM")
  Assert.equal(spy.plays[1], 11)
  Assert.equal(sound:currentMusic(), 11)
end

function T.explicit_same_music_command_restarts_through_the_generic_service()
  local controller, sound, spy, fdA = musicScenario()
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.plays = {}
  sound:playMusic(10)
  Assert.equal(#spy.plays, 1, "explicit same-ID playMusic must remain restart-capable")
  Assert.equal(sound:currentMusic(), 10)
end

function T.map_entry_with_play_disabled_does_not_change_music()
  local controller, sound, spy, fdA, fdB = musicScenario()
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.plays = {}
  spy.stops = {}
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = false })
  Assert.equal(#spy.plays, 0, "play=false map entry must not start music")
  Assert.equal(#spy.stops, 0, "play=false map entry must not stop music")
  Assert.equal(sound:currentMusic(), 10)
end

function T.production_position_is_read_through_a_narrow_fieldX_fieldZ_provider()
  local keyA = AudioFixture.key(1)
  local seqA =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = seqA }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound = GameSound.new({ provider = provider, player = enginePlayer })
  local gp = gameplayPlayer(34, 7)
  local fd = fieldDataWithSoundplates({
    {
      x = 2,
      xBounds = 2,
      z = 7,
      zBounds = 7,
      sequence = "SEQ_GS_T_WAKABA",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  local moves = 0
  local origMove = sound.moveSequenceVolume
  sound.moveSequenceVolume = function(self, ref, target, duration)
    moves = moves + 1
    return origMove(self, ref, target, duration)
  end
  controller:enterMap({ fieldData = fd }, { play = false })
  controller:updateField()
  Assert.equal(moves, 2, "the plate at local 2,7 should be selected from fieldX 34 (34%32=2)")
end

function T.entering_a_new_map_deactivates_the_source_environment_first()
  local keyA = AudioFixture.key(1)
  local bgmA =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local bgmB =
    seq(11, "SEQ_GS_UTSUGI_RABO", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor(
    { [10] = bgmA, [11] = bgmB, [20] = env },
    { [12] = bankWithSamples(12, "BANK_A", keyA), [13] = bankWithSamples(13, "BANK_B", AudioFixture.key(2)) }
  )
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fdA = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
  )
  fdA.mapId = 111
  local fdB = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_UTSUGI_RABO", night = "SEQ_GS_UTSUGI_RABO", flagOverrides = {}, traversalOverrides = {} }
  )
  fdB.mapId = 112
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fdB
    end,
  })
  controller:enterMap({ fieldData = fdA }, { play = true })
  local fdEnv = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  }, { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} })
  fdEnv.mapId = 111
  controller:enterMap({ fieldData = fdEnv }, { play = false })
  spy.moves = {}
  spy.stops = {}
  controller:updateField()
  Assert.equal(#spy.stops, 0, "first activation must not stop")
  spy.moves = {}
  spy.stops = {}
  controller:enterMap({ fieldData = fdB }, { clearMusicOverride = true, play = true })
  Assert.equal(#spy.stops, 1, "old environment must be faded first")
  Assert.equal(spy.stops[1].ref, 20)
  Assert.equal(spy.stops[1].duration, 10)
  Assert.equal(#spy.moves, 1, "old base field music must be restored")
  Assert.equal(spy.moves[1].ref, 10)
  Assert.equal(spy.moves[1].target, 128)
  Assert.equal(spy.moves[1].duration, 15)
end

function T.ordinary_bank_validation_remains_strict_while_the_explicit_donor_path_allows_mismatch()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 13, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor(
    { [10] = bgm, [20] = env },
    { [12] = bankWithSamples(12, "BANK_A", keyA), [13] = bankWithSamples(13, "BANK_B", keyB) }
  )
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local player = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  throwsCode("AUDIO_PLAYER_BANK_MISMATCH", function()
    player:play(player:createHandle(), provider:sequence(20), provider:bank(12))
  end)
  Assert.isTrue(type(player.playWithBankOverride) == "function", "explicit donor-bank start must exist")
  player:playWithBankOverride(player:createHandle(), provider:sequence(20), provider:bank(12))
  Assert.isTrue(player:isPlayerPlaying(2))
  local sound = GameSound.new({ provider = provider, player = player })
  Assert.isTrue(type(sound.playWithBankOverride) == "function", "GameSound explicit donor path must exist")
  sound:playWithBankOverride(20, 12)
  Assert.isTrue(player:isPlayerPlaying(2))
  local spy = { playWithBankCalls = {} }
  local orig = sound.playWithBankOverride
  ---@diagnostic disable-next-line: duplicate-set-field -- test spy
  sound.playWithBankOverride = function(self, seqRef, bankRef)
    spy.playWithBankCalls[#spy.playWithBankCalls + 1] = { seqRef = seqRef, bankRef = bankRef }
    return orig(self, seqRef, bankRef)
  end
  local fd = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = true,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  }, { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} })
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  controller:updateField()
  Assert.equal(#spy.playWithBankCalls, 1, "controller must route donor-bank plates through explicit path")
  Assert.equal(spy.playWithBankCalls[1].bankRef, 12)
end

function T.disabled_highest_plate_performs_no_fallback_and_preserves_prior_environment()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local envA =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local envB =
    seq(21, "SEQ_SE_GS_N_HUUSHA", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm, [20] = envA, [21] = envB }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fd = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_HUUSHA",
      useFieldMusicBank = false,
      bgmTarget = 32,
      ambientTarget = 48,
      disabledWhenFlag = 99,
    },
  })
  local gp2 = gameplayPlayer(5, 5)
  local controller2 = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState({}),
    fieldPosition = function()
      return gp2.fieldX, gp2.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  local fdOnlyLow = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  controller2:enterMap({ fieldData = fdOnlyLow }, { play = true })
  spy.moves = {}
  spy.stops = {}
  controller2:updateField()
  Assert.equal(#spy.moves, 2, "first plate should start with BGM and ambient moves")
  spy.moves = {}
  spy.stops = {}
  controller2._currentMap = { fieldData = fd }
  controller2._fieldMusic = 10
  controller2._eventState = eventState({ [99] = true })
  controller2:updateField()
  Assert.equal(#spy.moves, 0, "disabled selected plate must not start lower fallback and must not move volumes")
  Assert.equal(#spy.stops, 0, "disabled selected plate must not stop prior environment")
  Assert.equal(controller2._environment.sequence, 20, "remembered environment must remain unchanged")
end

function T.environment_identity_is_sequence_based_with_correct_volume_and_exit_transitions()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm, [20] = env }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fdA = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 10,
      z = 0,
      zBounds = 10,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local fdB = fieldDataWithSoundplates({
    {
      x = 20,
      xBounds = 30,
      z = 20,
      zBounds = 30,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 32,
      ambientTarget = 48,
    },
  })
  local gp = gameplayPlayer(5, 5)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fdA
    end,
  })
  controller:enterMap({ fieldData = fdA }, { play = true })
  spy.moves = {}
  spy.stops = {}
  controller:updateField()
  Assert.equal(#spy.stops, 0)
  Assert.equal(#spy.moves, 2, "first plate must schedule BGM and ambient moves")
  Assert.equal(spy.moves[1].duration, 15)
  Assert.equal(spy.moves[2].duration, 5)
  controller._currentMap = { fieldData = fdB }
  gp.fieldX, gp.fieldZ = 25, 25
  spy.moves = {}
  spy.stops = {}
  local envPlays = 0
  local origPlay = sound.play
  sound.play = function(self, ref)
    envPlays = envPlays + 1
    return origPlay(self, ref)
  end
  controller:updateField()
  sound.play = origPlay
  Assert.equal(envPlays, 0, "same sequence on different plate must not restart the sequence")
  Assert.equal(#spy.stops, 0, "same sequence must not stop")
  Assert.equal(#spy.moves, 2, "same sequence must still reapply BGM and ambient targets")
  controller._currentMap = {
    fieldData = fieldDataWithSoundplates(
      {},
      { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
    ),
  }
  gp.fieldX, gp.fieldZ = 50, 50
  spy.moves = {}
  spy.stops = {}
  controller:updateField()
  Assert.equal(spy.stops[1].ref, 20)
  Assert.equal(spy.stops[1].duration, 10)
  Assert.equal(spy.moves[1].target, 128)
  Assert.equal(spy.moves[1].duration, 15)
end

function T.temporary_music_does_not_change_the_environment_donor_bank()
  local keyA = AudioFixture.key(1)
  local keyB = AudioFixture.key(2)
  local baseBgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local tempBgm =
    seq(11, "SEQ_GS_BICYCLE", 13, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 13, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor(
    { [10] = baseBgm, [11] = tempBgm, [20] = env },
    { [12] = bankWithSamples(12, "BANK_A", keyA), [13] = bankWithSamples(13, "BANK_B", keyB) }
  )
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fd = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = true,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  spy.playWithBankCalls = {}
  sound:temporaryMusic(11)
  Assert.equal(sound:currentMusic(), 11)
  controller:processSoundplate()
  Assert.equal(#spy.playWithBankCalls, 1, "donor-bank plate must use explicit path")
  Assert.equal(spy.playWithBankCalls[1].bankRef, 12, "donor must be base field music bank, not temporary music bank")
  Assert.equal(controller._fieldMusic, 10, "controller base identity must remain base music")
end

function T.position_lookup_uses_field_coordinates_modulo_32_and_inclusive_edges()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm, [20] = env }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fd = fieldDataWithSoundplates({
    {
      x = 1,
      xBounds = 1,
      z = 1,
      zBounds = 1,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local gp = gameplayPlayer(33, 33)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  spy.moves = {}
  controller:updateField()
  Assert.equal(#spy.moves, 2, "33%32=1 matches inclusive plate at 1,1 when reading fieldX/fieldZ")
end

function T.forced_processing_clears_memory_without_pre_stop_and_restarts_same_plate()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local env =
    seq(20, "SEQ_SE_GS_N_SESERAGI", 12, 2, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm, [20] = env }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound, spy = recordingSound(provider, enginePlayer)
  local fd = fieldDataWithSoundplates({
    {
      x = 0,
      xBounds = 31,
      z = 0,
      zBounds = 31,
      sequence = "SEQ_SE_GS_N_SESERAGI",
      useFieldMusicBank = false,
      bgmTarget = 64,
      ambientTarget = 96,
    },
  })
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  controller:updateField()
  Assert.isTrue(controller._environment ~= nil)
  spy.stops = {}
  spy.moves = {}
  Assert.isTrue(type(controller.processSoundplate) == "function", "forced processing entry must exist")
  controller:processSoundplate()
  Assert.equal(#spy.stops, 0, "forced wipe must not pre-stop the old environment")
  Assert.isTrue(
    controller._environment ~= nil,
    "forced processing must restart same active plate after clearing memory"
  )
end

function T.begin_warp_raises_when_generated_field_data_is_missing()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound = GameSound.new({ provider = provider, player = enginePlayer })
  local fd = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
  )
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return nil
    end,
  })
  controller:enterMap({ fieldData = fd }, { play = true })
  sound:playMusic(10)
  Assert.throws(function()
    controller:beginWarp(9999)
  end)
end

function T.audio_owned_traversal_mutation_is_not_a_supported_operation()
  local keyA = AudioFixture.key(1)
  local bgm =
    seq(10, "SEQ_GS_T_WAKABA", 12, 1, { { op = "note", key = 60, velocity = 127, duration = 1 }, { op = "end" } })
  local provider = providerFor({ [10] = bgm }, { [12] = bankWithSamples(12, "BANK_A", keyA) })
  local mixer = VoiceMixer.new({ sampleRate = SAMPLE_RATE })
  local enginePlayer = newSequencePlayer({ sampleRate = SAMPLE_RATE, mixer = mixer, provider = provider })
  local sound = GameSound.new({ provider = provider, player = enginePlayer })
  local fd = fieldDataWithSoundplates(
    {},
    { day = "SEQ_GS_T_WAKABA", night = "SEQ_GS_T_WAKABA", flagOverrides = {}, traversalOverrides = {} }
  )
  local gp = gameplayPlayer(0, 0)
  local controller = FieldAudioController.new({
    sound = sound,
    provider = provider,
    eventState = eventState(),
    fieldPosition = function()
      return gp.fieldX, gp.fieldZ
    end,
    dayNight = function()
      return "day"
    end,
    fieldDataForMap = function()
      return fd
    end,
  })
  ---@diagnostic disable-next-line: undefined-field -- negative test: traversal setter must not exist
  Assert.isTrue(controller.setTraversalMode == nil, "controller must not expose an audio-owned traversal setter")
end

return { tests = T }
