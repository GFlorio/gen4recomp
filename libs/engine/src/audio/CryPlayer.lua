-- CryPlayer: the production cry data path. HGSS cries are played as
-- SE-style sounds on the shared effect players (the script's
-- ScrCmd_PlayCry passes a species/form and the cry voice data lives
-- outside the audio archive), so the cry boundary plays the referenced cry
-- as a short SE-style stand-in sequence through the same engine audio
-- stack, on the effect-player slot the derived player index declares. The
-- stand-in carries the species through its pitch (the only cry identity
-- the script operand provides). PCM rendering stays the output sink's
-- business; this module only starts the stand-in through the player and
-- reports when it has finished. Pure domain module: no love dependency.

local AudioCache = require("libs.assets.src.AudioCache")

local CryPlayer = {}
CryPlayer.__index = CryPlayer

-- The effect-player slot the stand-in occupies. The derived player index
-- declares players 0..8; the field-script roles use 1/7 (BGM), 2/4
-- (fanfare), and 3/4/5 (effects), so the cry slot overlaps the effect
-- role exactly as HGSS cries do.
local CRY_PLAYER_ID = 3

-- The stand-in bank: one direct square voice, so the cry needs no sample
-- payload.
local CRY_BANK = {
  schema = AudioCache.BANK_SCHEMA,
  id = 2000,
  symbol = "BANK_CRY_STANDIN",
  instruments = {
    [0] = {
      kind = "direct",
      voice = {
        generator = { kind = "square", duty = 4 },
        originalKey = 60,
        envelope = { attack = 0, decay = 0, sustain = 127, release = 0 },
        pan = 64,
      },
    },
  },
}

-- The pitch of the stand-in carries the species identity: HGSS cries vary
-- by species, and the script operand is the only reference the cry
-- boundary receives.
local function midiKeyFor(species)
  return 48 + (species % 24)
end

-- The stand-in sequence for one cry: a short two-note call on the cry
-- slot, so the player reports the slot free again when the call ends.
local function standinSequence(species)
  local key = midiKeyFor(species)
  return {
    schema = AudioCache.SEQUENCE_SCHEMA,
    id = 2000,
    symbol = "SEQ_CRY_STANDIN",
    bankId = 2000,
    player = {
      id = CRY_PLAYER_ID,
      initialVolume = 127,
      playerPriority = 64,
      channelPriority = 64,
    },
    program = {
      entry = 1,
      initialTrackMask = 0x0001,
      instructions = {
        { op = "program", program = 0 },
        { op = "note", key = key, velocity = 127, duration = 3 },
        { op = "note", key = key + 2, velocity = 96, duration = 3 },
        { op = "end" },
      },
    },
  }
end

---@class CryPlayer
---@field new fun(opts: { player: SequencePlayer }): CryPlayer
---@field play fun(self: CryPlayer, species: integer, form: integer)
---@field isFinished fun(self: CryPlayer): boolean

---@param opts { player: SequencePlayer }
---@return CryPlayer
function CryPlayer.new(opts)
  assert(opts and opts.player, "cry player requires the engine player")
  return setmetatable({
    _player = opts.player,
    _handle = opts.player:createHandle(),
  }, CryPlayer)
end

-- Starts the referenced cry as a stand-in on the cry slot. Cry replacement is
-- an explicit policy of this subsystem, so an active prior cry is stopped
-- before the private handle is reused.
---@param species integer
---@param form integer
function CryPlayer:play(species, form)
  self._player:stopHandle(self._handle)
  self._player:play(self._handle, standinSequence(species), CRY_BANK)
end

-- True once the cry slot's sequence has ended.
---@return boolean
function CryPlayer:isFinished()
  return not self._player:isPlayerPlaying(CRY_PLAYER_ID)
end

return CryPlayer
