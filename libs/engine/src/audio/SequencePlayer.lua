-- The g4 sequence-IR interpreter. It owns NNS-style players,
-- active sequences, tracks, program counters, track wait counters, call
-- stacks, loops, tempo, and track parameters, and drives a VoiceMixer with
-- voice commands. It interprets project instruction IR, never SSEQ. The
-- tick clock is the NNS relationship verified from GBATEK ("DS Sound Files -
-- SSEQ"): a quarter note is 48 ticks and tempo is BPM (1..240, default
-- 120). Ticks come from an exact integer accumulator per player instance:
-- every output frame adds tempo*48, and a tick fires each time the
-- accumulator reaches sampleRate*60 (the frames-per-tick identity
-- sampleRate*60/(tempo*48) without float drift) -- NOT the 30 Hz field tick
-- and not MIDI PPQN. A track's wait is an integer tick count; a note-off
-- lands on the tick boundary after the boundary frame's render, so a
-- 1-tick note at tempo 120 occupies exactly 500 frames at 48 kHz, and a
-- re-triggered note restarts its sample. Tempo changes apply to the
-- accumulator rate from the next frame (the accumulator keeps its residue,
-- like the DS timer). Tracks are monophonic: a note occupies its track for
-- its whole duration. loop_end jumps back to its target while the loop
-- count is positive (loop_begin count 0, as in the real HGSS jingle, plays
-- the body once). Random amount operands resolve through a deterministic
-- per-play RNG. Rendering is per-frame, so command boundaries inside a
-- buffer apply at their sample index, and the accumulator and waits are
-- instance state carried across render calls, so chunk sizes never change
-- the result. play(sequence, bank) starts the sequence on its player id;
-- the same player id replaces the running sequence (releasing its voices),
-- different player ids mix. A track holds exactly the channel the mixer
-- assigned; replacing a sequence, re-opening a running track, or stop()
-- releases those channels.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.engine.src.FieldErrors")

---@class SequencePlayer
---@field private _sampleRate integer
---@field private _mixer VoiceMixer
---@field private _provider AudioAssetProvider
---@field private _players table<integer, table>
---@field new fun(opts: { sampleRate: integer, mixer: VoiceMixer, provider: AudioAssetProvider }): SequencePlayer
---@field play fun(self: SequencePlayer, sequence: table, bank: table)
---@field render fun(self: SequencePlayer, frames: integer): integer[]
---@field stop fun(self: SequencePlayer)
---@field isPlaying fun(self: SequencePlayer): boolean

local SequencePlayer = {}
SequencePlayer.__index = SequencePlayer

local DEFAULT_TEMPO = 120
local DEFAULT_BEND_RANGE = 2
-- Upper bound on instructions executed without a wait gate; a program that
-- exceeds it is an authored runaway (e.g. a jump to itself) and fails
-- loudly instead of hanging the render loop.
local MAX_UNGATED_STEPS = 1024

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

-- A deterministic per-play RNG (LCG) so random operands resolve identically
-- across plays of the same program.
local function newRng()
  local state = 0x2545F491
  return function()
    state = (state * 1103515245 + 12345) % 4294967296
    return state / 4294967296
  end
end

-- Resolves a normalized amount operand: a plain value passes through, a
-- random record draws from the per-play RNG, anything else (e.g. a variable
-- operand, which the player has no variable state to resolve) is an
-- attributed failure.
local function resolveAmount(amount, rng)
  if type(amount) == "number" then
    return amount
  end
  if amount.kind == "random" then
    return amount.min + math.floor(rng() * (amount.max - amount.min + 1))
  end
  Errors.raise(FieldErrors.AUDIO_PLAYER_UNSUPPORTED_AMOUNT, "unsupported amount operand in sequence", {
    kind = amount.kind,
  })
end

local function newTrack(entry)
  return {
    pc = entry,
    ended = false,
    gated = false,
    wait = 0,
    channel = nil,
    program = 0,
    volume = 127,
    expression = 127,
    pan = 64,
    transpose = 0,
    bend = 64,
    bendRange = DEFAULT_BEND_RANGE,
    callStack = {},
    loopStack = {},
  }
end

-- Selects the leaf voice an instrument plays for a note key: direct is the
-- single voice, key_split matches the key's range, drum_set indexes voices
-- by key within its low/high bounds. Returns nil for a key with no voice
-- (the note is silent but still gates the track).
local function selectVoice(instrument, key)
  if instrument.kind == "direct" then
    return instrument.voice
  end
  if instrument.kind == "key_split" then
    for _, range in ipairs(instrument.ranges) do
      if key >= range.lowKey and key <= range.highKey then
        return range.voice
      end
    end
    return nil
  end
  if instrument.kind == "drum_set" then
    if key < instrument.lowKey or key > instrument.highKey then
      return nil
    end
    return instrument.voices[key - instrument.lowKey + 1]
  end
  assert(false, "unknown instrument kind")
end

-- Starts the note's voice on the mixer and returns the assigned channel (or
-- nil for a silent note). The voice spec carries the decoded PCM, wave rate
-- and loop window from the provider, the effective key (note key plus
-- transpose and pitch-bend semitones), the player volume folded into the
-- track volume, the effective pan (voice pan offset by the track pan
-- around 64), and the priorities and channel mask from the sequence's
-- player record.
local function startNote(self, instance, track, key, velocity)
  local instrument = instance.bank.instruments[track.program]
  if instrument == nil then
    Errors.raise(FieldErrors.AUDIO_PLAYER_INSTRUMENT_UNKNOWN, "no instrument for program " .. tostring(track.program), {
      program = track.program,
      bankId = instance.bank.id,
    })
  end
  local voice = selectVoice(instrument, key)
  if voice == nil then
    return nil
  end
  local spec = { generator = voice.generator }
  if voice.generator.kind == "sample" then
    local sample = self._provider:loadSample(voice.generator.sample)
    spec.sampleRate = sample.metadata.sampleRate
    spec.pcm = sample.pcm
    spec.loop = sample.metadata.loop
    spec.rootKey = voice.rootKey
  end
  local sequence = instance.sequence
  spec.key = key + track.transpose + (track.bend - 64) * track.bendRange / 128
  spec.velocity = velocity
  spec.volume = math.floor(track.volume * sequence.player.initialVolume / 127 + 0.5)
  spec.expression = track.expression
  spec.envelope = voice.envelope
  spec.pan = clamp(voice.pan + track.pan - 64, 0, 127)
  spec.channelPriority = sequence.player.channelPriority
  spec.playerPriority = sequence.player.playerPriority
  spec.channelMask = instance.channelMask
  return self._mixer:noteOn(spec)
end

-- Executes one instruction, mutating the track, and returns the next
-- program counter. Gating instructions (note/rest) set the track's wait;
-- fin ends the track; open_track spawns the target track and lets the
-- current track continue; loop_end jumps while its count is positive.
local function execute(self, instance, track, instruction)
  local op = instruction.op
  if op == "note" then
    track.channel = startNote(self, instance, track, instruction.key, instruction.velocity)
    track.gated = true
    track.wait = instruction.duration
    return track.pc + 1
  end
  if op == "rest" then
    track.channel = nil
    track.gated = true
    track.wait = instruction.duration
    return track.pc + 1
  end
  if op == "fin" then
    track.ended = true
    return nil
  end
  if op == "program" then
    track.program = instruction.program
  elseif op == "jump" then
    return instruction.target
  elseif op == "call" then
    track.callStack[#track.callStack + 1] = track.pc + 1
    return instruction.target
  elseif op == "return" then
    assert(#track.callStack > 0, "return with an empty call stack")
    return table.remove(track.callStack)
  elseif op == "open_track" then
    local previous = instance.tracks[instruction.track]
    if previous ~= nil and previous.channel ~= nil then
      self._mixer:noteOff(previous.channel)
    end
    instance.tracks[instruction.track] = newTrack(instruction.target)
  elseif op == "tempo" then
    instance.tempo = resolveAmount(instruction.amount, instance.rng)
  elseif op == "pan" then
    track.pan = resolveAmount(instruction.amount, instance.rng)
  elseif op == "volume" then
    track.volume = resolveAmount(instruction.amount, instance.rng)
  elseif op == "expression" then
    track.expression = resolveAmount(instruction.amount, instance.rng)
  elseif op == "transpose" then
    track.transpose = resolveAmount(instruction.amount, instance.rng)
  elseif op == "pitch_bend" then
    track.bend = resolveAmount(instruction.amount, instance.rng)
  elseif op == "pitch_bend_range" then
    track.bendRange = resolveAmount(instruction.amount, instance.rng)
  elseif op == "loop_begin" then
    assert(type(instruction.count) == "number", "loop_begin requires a count")
    track.loopStack[#track.loopStack + 1] = { remaining = instruction.count }
  elseif op == "loop_end" then
    local frame = track.loopStack[#track.loopStack]
    assert(frame, "loop_end without a matching loop_begin")
    if frame.remaining > 0 then
      frame.remaining = frame.remaining - 1
      return instruction.target
    end
    table.remove(track.loopStack)
  else
    Errors.raise(FieldErrors.AUDIO_PLAYER_UNSUPPORTED_OP, "unsupported sequence instruction op", {
      op = op,
      pc = track.pc,
    })
  end
  return track.pc + 1
end

-- Executes instructions until the track is gated (waiting on a note/rest)
-- or ended, with a bounded step budget so a runaway non-gating loop fails
-- instead of hanging.
local function fetch(self, instance, track)
  local steps = 0
  while not track.ended and not track.gated do
    local instruction = instance.sequence.program.instructions[track.pc]
    assert(instruction, "program counter past the instruction list")
    track.pc = execute(self, instance, track, instruction)
    steps = steps + 1
    if steps > MAX_UNGATED_STEPS then
      Errors.raise(
        FieldErrors.AUDIO_PLAYER_UNBOUNDED_EXECUTION,
        "sequence executed too many instructions without a wait",
        {
          playerId = instance.id,
        }
      )
    end
  end
end

local function releaseInstance(self, instance)
  for _, track in pairs(instance.tracks) do
    if track.channel ~= nil then
      self._mixer:noteOff(track.channel)
      track.channel = nil
    end
  end
end

function SequencePlayer.new(opts)
  assert(
    opts and opts.sampleRate and opts.mixer and opts.provider,
    "SequencePlayer requires sampleRate, mixer and provider"
  )
  return setmetatable({
    _sampleRate = opts.sampleRate,
    _mixer = opts.mixer,
    _provider = opts.provider,
    _players = {},
  }, SequencePlayer)
end

-- Starts `sequence` on its player id with `bank`. The bank must be the
-- sequence's bankId; a sequence already running on the same player id is
-- replaced (its voices released) exactly once, so the new note never mixes
-- with the old one.
function SequencePlayer:play(sequence, bank)
  assert(sequence and bank, "play requires a sequence and a bank")
  if bank.id ~= sequence.bankId then
    Errors.raise(
      FieldErrors.AUDIO_PLAYER_BANK_MISMATCH,
      "bank " .. tostring(bank.id) .. " does not match sequence bankId " .. tostring(sequence.bankId),
      {
        bankId = bank.id,
        sequenceBankId = sequence.bankId,
      }
    )
  end
  local playerId = sequence.player.id
  local playerRecord = self._provider:player(playerId)
  local previous = self._players[playerId]
  if previous ~= nil then
    releaseInstance(self, previous)
  end
  self._players[playerId] = {
    id = playerId,
    sequence = sequence,
    bank = bank,
    channelMask = playerRecord.channelMask,
    tempo = DEFAULT_TEMPO,
    acc = 0,
    rng = newRng(),
    tracks = { [0] = newTrack(sequence.program.entry) },
  }
end

-- Renders `frames` output frames of interleaved stereo int16 PCM. The
-- sequencer advances once per output frame: not-gated tracks fetch their
-- next instruction first, the mixer renders the frame, then each instance's
-- tick accumulator adds tempo*48 (a tick fires per sampleRate*60 units) and
-- every tick decrements each gated track's integer wait, releasing
-- completed gates and fetching the following instructions. Per-frame
-- processing with instance-carried state keeps rendering independent of
-- chunk size.
---@param frames integer
---@return integer[]
function SequencePlayer:render(frames)
  local out = {}
  for frame = 1, frames do
    for _, instance in pairs(self._players) do
      for _, track in pairs(instance.tracks) do
        if not track.ended and not track.gated then
          fetch(self, instance, track)
        end
      end
    end
    local pcm = self._mixer:render(1)
    out[#out + 1] = pcm[1]
    out[#out + 1] = pcm[2]
    for _, instance in pairs(self._players) do
      instance.acc = instance.acc + instance.tempo * 48
      while instance.acc >= self._sampleRate * 60 do
        instance.acc = instance.acc - self._sampleRate * 60
        for _, track in pairs(instance.tracks) do
          if track.gated then
            track.wait = track.wait - 1
            if track.wait <= 0 then
              if track.channel ~= nil then
                self._mixer:noteOff(track.channel)
                track.channel = nil
              end
              track.gated = false
              if not track.ended then
                fetch(self, instance, track)
              end
            end
          end
        end
      end
    end
  end
  return out
end

-- Releases every voice of every active sequence and clears the players.
function SequencePlayer:stop()
  for _, instance in pairs(self._players) do
    releaseInstance(self, instance)
  end
  self._players = {}
end

-- True while any track of any active sequence is still running.
function SequencePlayer:isPlaying()
  for _, instance in pairs(self._players) do
    for _, track in pairs(instance.tracks) do
      if not track.ended then
        return true
      end
    end
  end
  return false
end

return SequencePlayer
