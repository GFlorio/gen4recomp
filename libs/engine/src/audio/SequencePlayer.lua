-- The g4 sequence-IR interpreter. It owns NNS-style players, active
-- sequences, tracks, program counters, track wait counters, call stacks,
-- loops, tempo, player variables, and track parameters, and drives a
-- VoiceMixer with the migrated voice spec ({channel, generation} handles,
-- trackVolume/playerVolume never folded, raw track pan offset, bend folded
-- into key). It interprets project instruction IR, never SSEQ. The tick
-- clock is the NNS relationship verified from GBATEK ("DS Sound Files -
-- SSEQ") and the ARM7 NitroSDK player (SND_seq.c: SND_TIMER_RATE 240 at the
-- 192 Hz sound interval): a quarter note is 48 ticks and tempo is BPM
-- (1..240, default 120). Ticks come from an exact integer accumulator per
-- player instance: every output frame adds tempo*48, and a tick fires each
-- time the accumulator reaches sampleRate*60 (the frames-per-tick identity
-- sampleRate*60/(tempo*48) without float drift) -- NOT the 30 Hz field tick
-- and not MIDI PPQN. A track's wait is an integer tick count; a note-off
-- lands on the tick boundary after the boundary frame's render, so a
-- 1-tick note at tempo 120 occupies exactly 500 frames at 48 kHz, and a
-- re-triggered note restarts its sample. Tempo changes apply to the
-- accumulator rate from the next frame (the accumulator keeps its residue,
-- like the DS timer).
--
-- Track state follows the SDK: wait ticks, the note-finish hold (a
-- zero-length note under note-wait is a note-FINISH wait, never a one-tick
-- gate), note-wait (default true), a polyphonic voice collection of
-- {handle, length} pairs (never a single channel), tie, mute, program,
-- priority (default 64), volume/expression 127, the raw pan offset
-- (default 0; the 0xC0 pan command stores amount-64), transpose, bend 64,
-- bend range 2, nullable envelope stage overrides (0xD0-0xD3, applied to a
-- note only when set), the comparison flag, and the call/loop stacks.
-- Fresh tracks gate notes by their duration; 0xC7 note_wait clears the flag
-- so composers pair notes with explicit 0x80 waits, and each ringing
-- voice's own length bounds its ring independently of gates (the NNS
-- channel length). WAIT 0 does not gate: the next instruction runs in the
-- same pass. Releases happen only on open_track replacement, a tie-flag
-- change, mute mode 2/3, sequence replacement, and stop; a tied note over
-- an active voice reuses it in place (updateVoice key/velocity, no noteOn,
-- no noteOff). Loops follow the ARM7 player (SND_seq.c): loop_begin pushes
-- a frame holding the count and the return index (the instruction after the
-- begin, the SDK's posCallStack); loop_end decrements and jumps back while
-- the count is positive, exits when it reaches zero, jumps forever while
-- the count is zero (the SDK's loopCount 0 -- the real SEQ_GS_P_SAFARI_ROAD),
-- and is a no-op with no active frame. A return with no active call is
-- likewise a no-op. Random amount operands resolve through the player's
-- injected or default RNG (created once at construction, never reseeded per
-- play); variables live in the SDK 16-local/16-global domain with s16
-- arithmetic (addvar/subvar/mulvar/divvar/shiftvar/randomvar, div-by-zero
-- skips, negative shifts shift right). LFO modulation, pitch sweep and
-- portamento commands are accepted without effect.
--
-- Rendering is per-frame, so command boundaries inside a buffer apply at
-- their sample index, and the accumulator, waits, and the frame count are
-- instance/player state carried across render calls, so chunk sizes never
-- change the result. Players process ascending player number and tracks
-- ascending track number over the fixed NNS domains (16 players x 16
-- tracks), so contested allocation is deterministic. The mixer renders only
-- while at least one player is active, so the mixer's control cadence is
-- aligned with a play (idle frames before a play never shift the release
-- phase). At the mixer's control-period cadence the player pushes the
-- current track values to every active voice handle (the NNS
-- TrackUpdateChannel per main). play(sequence, bank) starts the sequence on
-- its player id and runs its entry program immediately; the same player id
-- replaces the running sequence (releasing its voices), different player
-- ids mix.

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.engine.src.audio.AudioErrors")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")
local bit = require("bit")

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
---@field setFader fun(self: SequencePlayer, playerId: integer, level: integer)
---@field pausePlayer fun(self: SequencePlayer, playerId: integer)
---@field resumePlayer fun(self: SequencePlayer, playerId: integer)

local SequencePlayer = {}
SequencePlayer.__index = SequencePlayer

local DEFAULT_TEMPO = 120
local DEFAULT_BEND_RANGE = 2
-- The fixed NNS scheduling domains (SND_seq.c SND_PLAYER_COUNT /
-- SND_TRACK_COUNT): players and tracks iterate ascending over these bounds,
-- never in Lua table order, so contested allocation is deterministic.
local PLAYER_COUNT = 16
local TRACK_COUNT = 16
-- The 192 Hz sound interval (SND_main.c SndThread): the mixer fires one
-- control step per outputRate/192 frames, and the player's per-main track
-- value pushes and its release-end computations align with that cadence.
local SOUND_INTERVAL = 192
-- The envelope's fully-attenuated start (SND_exChannel.c ExChannelStart):
-- the -723 dB floor scaled by the envelope's 128 shift.
local ENV_START = 723 * 128
-- The SDK variable domain: vars 0..15 are player-local, 16..31 the shared
-- global variables (SND_work_shared localVars[16] per player plus
-- globalVars[16]).
local LOCAL_VAR_COUNT = 16
-- The host safety budget: an upper bound on instructions executed without a
-- wait gate. A program that exceeds it is an authored runaway (e.g. a jump
-- to itself) and fails loudly instead of hanging the render loop.
local HOST_SAFETY_STEP_BUDGET = 1024

local function clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

-- The s16 domain of the SDK variables: values wrap to the signed 16-bit
-- range on every store.
local function toS16(value)
  value = value % 65536
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

-- A deterministic default RNG (LCG) so random operands resolve identically
-- across runs. Created once per player at construction; plays share it and
-- never reseed.
local function newRng()
  local state = 0x2545F491
  return function()
    state = (state * 1103515245 + 12345) % 4294967296
    return state / 4294967296
  end
end

-- Reads an SDK variable: 0..15 player-local, 16..31 global.
local function varRead(self, instance, var)
  if var < LOCAL_VAR_COUNT then
    return instance.localVars[var] or 0
  end
  return self._globalVars[var - LOCAL_VAR_COUNT] or 0
end

-- Stores an SDK variable in its domain, wrapped to the s16 range.
local function varWrite(self, instance, var, value)
  value = toS16(value)
  if var < LOCAL_VAR_COUNT then
    instance.localVars[var] = value
  else
    self._globalVars[var - LOCAL_VAR_COUNT] = value
  end
end

-- Resolves a normalized amount operand against the player instance: a plain
-- value passes through, a random record draws from the player's RNG, a
-- variable record reads the SDK variable it names, and anything else (an
-- unknown shape or a variable record without a var id) is an attributed
-- failure.
local function resolveAmount(self, amount, instance)
  if type(amount) == "number" then
    return amount
  end
  if amount.kind == "random" then
    return amount.min + math.floor(self._rng() * (amount.max - amount.min + 1))
  end
  if amount.kind == "variable" then
    if type(amount.var) ~= "number" then
      Errors.raise(AudioErrors.AUDIO_PLAYER_UNSUPPORTED_AMOUNT, "variable amount requires a var id", {
        kind = amount.kind,
      })
    end
    return varRead(self, instance, amount.var)
  end
  Errors.raise(AudioErrors.AUDIO_PLAYER_UNSUPPORTED_AMOUNT, "unsupported amount operand in sequence", {
    kind = amount.kind,
  })
end

local function newTrack(entry)
  return {
    pc = entry,
    ended = false,
    gated = false,
    wait = 0,
    -- The note-finish hold: set by a zero-length note under note-wait; the
    -- track stays blocked until that note's release completes.
    noteFinishWait = false,
    -- The track's ringing voices (polyphonic): a list of {handle, length}
    -- pairs -- the mixer {channel, generation} handle and the voice's
    -- remaining length in ticks (the NNS per-channel length), so a note
    -- never rings past its own duration into a later wait.
    voices = {},
    -- Note gating: fresh tracks gate notes by their duration (the NNS
    -- TrackStart initialization sets noteWait); 0xC7 note_wait clears it so
    -- composers pair notes with explicit waits.
    noteWait = true,
    tie = false,
    mute = 0,
    program = 0,
    priority = 64,
    volume = 127,
    expression = 127,
    -- The raw track pan offset (the NNS 0xC0 pan command stores amount-64;
    -- the mixer scales it into the final pan register).
    pan = 0,
    transpose = 0,
    bend = 64,
    bendRange = DEFAULT_BEND_RANGE,
    -- Per-track envelope stage overrides (the NNS 0xD0-0xD3 commands), nil
    -- until set; a set override replaces exactly that stage of a note's
    -- envelope.
    attack = nil,
    decay = nil,
    sustain = nil,
    release = nil,
    cmp = false,
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

-- The note's effective envelope: a set track override replaces exactly that
-- stage of the voice envelope.
local function effectiveEnvelope(track, voice)
  return {
    attack = track.attack or voice.envelope.attack,
    decay = track.decay or voice.envelope.decay,
    sustain = track.sustain or voice.envelope.sustain,
    release = track.release or voice.envelope.release,
  }
end

-- The note's effective key: the note key plus transpose and pitch-bend
-- semitones (bend 64 is no bend; the mixer has no bend field).
local function noteKey(track, key)
  return key + track.transpose + (track.bend - 64) * track.bendRange / 128
end

-- The control steps until the note's release stops (NnsSoundMath
-- .releaseStopSteps with the note's own inputs): envAttenuation is the
-- mixer's envelope after the note's first control step, so the player's
-- countdown matches the mixer's release-stop computation.
local function releaseStepsForNote(instance, track, velocity, envelope)
  local attack = NnsSoundMath.attackCoefficient(envelope.attack)
  local envAttenuation = -math.floor(ENV_START * attack / 256)
  return NnsSoundMath.releaseStopSteps({
    velocity = velocity,
    envAttenuation = envAttenuation,
    trackVolume = clamp(track.volume, 0, 127),
    expression = clamp(track.expression, 0, 127),
    playerVolume = clamp(instance.volume, 0, 127),
    fader = 0,
    releaseCoeff = NnsSoundMath.decayCoefficient(envelope.release),
  })
end

-- The frames until the end of the release's last control step: the frames
-- to the next control-period boundary plus (steps-1) full periods plus one.
-- The noteOff always lands after the current frame's control step (the tick
-- follows the frame's render), so the first release decrement fires at the
-- NEXT boundary; the trailing +1 covers the stop-step frame itself (the
-- finish wait clears after it sounds). The countdown also consumes one
-- decrement in the frame that sets it, which the +1 accounts for.
local function framesToReleaseEnd(self, steps)
  local period = self._controlPeriod
  local toNextStep = period - (self._frameCount + 1) % period + 1
  return toNextStep + (steps - 1) * period
end

-- Starts the note's voice on the mixer and returns its {channel, generation}
-- handle (or nil for a silent note). The voice spec carries the decoded PCM,
-- wave rate and loop window from the provider, the effective key (note key
-- plus transpose and pitch-bend semitones), the raw track pan offset and the
-- track/player priorities and channel mask from the sequence's player record
-- (nothing is folded into the track volume).
local function startNote(self, instance, track, key, velocity)
  -- A program the bank does not define is a silent note (the NNS
  -- SND_ReadInstData failure path): the real corpus references instruments
  -- whose SBNK records are unused/placeholder and the DS plays silence.
  local instrument = instance.bank.instruments[track.program]
  if instrument == nil then
    return nil
  end
  local voice = selectVoice(instrument, key)
  if voice == nil then
    return nil
  end
  local spec = { generator = voice.generator }
  if voice.generator.kind == "sample" then
    local sample = self._provider:loadSample(voice.generator.sample)
    spec.sampleRate = sample.metadata.sampleRate
    spec.baseTimer = sample.metadata.baseTimer
    spec.pcm = sample.pcm
    spec.loop = sample.metadata.loop
    spec.loopEnabled = sample.metadata.loopEnabled
  end
  local sequence = instance.sequence
  spec.originalKey = voice.originalKey
  spec.key = noteKey(track, key)
  spec.velocity = velocity
  -- The dB table domain is 0..127 while the asset schemas carry u8 volumes,
  -- so the player bounds them at the mixer boundary (the SDK reads past its
  -- 128-entry table here).
  spec.trackVolume = clamp(track.volume, 0, 127)
  spec.expression = clamp(track.expression, 0, 127)
  spec.playerVolume = clamp(instance.volume, 0, 127)
  spec.envelope = effectiveEnvelope(track, voice)
  spec.pan = voice.pan
  spec.trackPanOffset = track.pan
  spec.trackPriority = track.priority
  spec.playerPriority = sequence.player.playerPriority
  spec.channelMask = instance.channelMask
  return self._mixer:noteOn(spec), voice
end

-- Releases every voice handle of a track (a soft release; each voice rings
-- out its release tail) and clears the collection.
local function releaseTrackVoices(self, track)
  for index = 1, #track.voices do
    self._mixer:noteOff(track.voices[index].handle)
  end
  track.voices = {}
end

-- Executes one instruction, mutating the track, and returns the next
-- program counter. Gating instructions (note/wait) set the track's wait;
-- end ends the track; open_track spawns the target track and lets the
-- current track continue; loop_end jumps to its loop frame's return index
-- while the frame's count is positive (forever at count 0) and falls through
-- when the count reaches zero.
local function execute(self, instance, track, instruction)
  local op = instruction.op
  if op == "note" then
    -- Polyphonic: a new note never releases a ringing one; every note
    -- appends its own voice (or reuses the tied head) and each voice's
    -- length bounds its ring independently. A zero-length note under
    -- note-wait is a note-FINISH wait (the NNS noteFinishWait), not a
    -- one-tick gate: the track stays blocked until the note's release
    -- completes. Muted tracks play no voice but gate exactly like normal
    -- notes.
    local length = resolveAmount(self, instruction.duration, instance)
    local entry
    if track.mute == 0 then
      if track.tie and #track.voices > 0 then
        -- Tied re-note: reuse the most recent voice in place (the NNS
        -- TrackPlayNote tie path): no noteOn, no noteOff; the key and
        -- velocity change at the next control step and the envelope never
        -- restarts.
        entry = track.voices[#track.voices]
        self._mixer:updateVoice(entry.handle, {
          key = noteKey(track, instruction.key),
          velocity = instruction.velocity,
        })
        entry.length = length
        if track.noteWait and length == 0 then
          local instrument = instance.bank.instruments[track.program]
          local voice = instrument and selectVoice(instrument, instruction.key) or nil
          entry.finishSteps = voice
              and releaseStepsForNote(instance, track, instruction.velocity, effectiveEnvelope(track, voice))
            or nil
        end
      else
        local handle, voice = startNote(self, instance, track, instruction.key, instruction.velocity)
        if handle ~= nil then
          entry = { handle = handle, length = length }
          if track.noteWait and length == 0 then
            entry.finishSteps =
              releaseStepsForNote(instance, track, instruction.velocity, effectiveEnvelope(track, voice))
          end
          track.voices[#track.voices + 1] = entry
        end
      end
    end
    if track.noteWait then
      track.gated = true
      track.wait = length
      if length == 0 then
        track.noteFinishWait = true
        if entry == nil or entry.finishSteps == nil then
          -- A silent zero-length note has no release to wait for: the hold
          -- clears at the next frame like the SDK's empty channel list.
          track.finishWaitFrames = 0
        end
      end
    end
    return track.pc + 1
  end
  if op == "wait" then
    -- 0x80: gate the track without releasing a ringing note (the note's own
    -- voice length bounds its ring). A zero wait does not gate at all: the
    -- next instruction runs in the same pass.
    local duration = resolveAmount(self, instruction.duration, instance)
    if duration > 0 then
      track.gated = true
      track.wait = duration
    end
    return track.pc + 1
  end
  if op == "end" then
    track.ended = true
    return nil
  end
  if op == "program" then
    -- The program operand is normalized (plain number, random, or variable):
    -- variable-program references select the program the variable names.
    track.program = resolveAmount(self, instruction.program, instance)
  elseif op == "jump" then
    return instruction.target
  elseif op == "call" then
    track.callStack[#track.callStack + 1] = track.pc + 1
    return instruction.target
  elseif op == "return" then
    -- The SDK's 0xFD with an empty call stack (depth 0) is a no-op: real
    -- tracks end with a top-level return, and mid-program top-level
    -- returns fall through to the next instruction.
    if #track.callStack > 0 then
      return table.remove(track.callStack)
    end
  elseif op == "open_track" then
    -- Replacing a running track releases its voices; the new track starts
    -- fresh at the target.
    local previous = instance.tracks[instruction.track]
    if previous ~= nil then
      releaseTrackVoices(self, previous)
    end
    instance.tracks[instruction.track] = newTrack(instruction.target)
  elseif op == "tempo" then
    instance.tempo = resolveAmount(self, instruction.amount, instance)
  elseif op == "pan" then
    -- 0xC0 stores par-0x40: the raw track pan offset.
    track.pan = resolveAmount(self, instruction.amount, instance) - 64
  elseif op == "volume" then
    track.volume = resolveAmount(self, instruction.amount, instance)
  elseif op == "master_volume" then
    -- 0xC2 is the PLAYER volume: it changes every voice of the player.
    instance.volume = resolveAmount(self, instruction.amount, instance)
  elseif op == "expression" then
    track.expression = resolveAmount(self, instruction.amount, instance)
  elseif op == "transpose" then
    track.transpose = resolveAmount(self, instruction.amount, instance)
  elseif op == "pitch_bend" then
    track.bend = resolveAmount(self, instruction.amount, instance)
  elseif op == "pitch_bend_range" then
    track.bendRange = resolveAmount(self, instruction.amount, instance)
  elseif op == "note_wait" then
    -- 0xC7 sets/clears the note-gating flag (u8, nonzero = set).
    track.noteWait = resolveAmount(self, instruction.amount, instance) ~= 0
  elseif op == "priority" then
    track.priority = resolveAmount(self, instruction.amount, instance)
  elseif op == "tie" then
    -- 0xC8: when the tie flag changes (either direction) the track
    -- releases its voices; a tied note over an active voice reuses it.
    local value = resolveAmount(self, instruction.amount, instance) ~= 0
    if value ~= track.tie then
      releaseTrackVoices(self, track)
    end
    track.tie = value
  elseif op == "mute" then
    -- SDK TrackMute: 0 unmutes, 1 mutes future notes (they still gate the
    -- track), 2 additionally releases the track's voices, 3 releases and
    -- drops them (the SDK's fast release + free; our mixer's soft release
    -- keeps the ring-out). Other mode values are no-ops.
    local mode = resolveAmount(self, instruction.amount, instance)
    if mode == 0 then
      track.mute = 0
    elseif mode == 1 then
      track.mute = 1
    elseif mode == 2 then
      track.mute = 2
      for index = 1, #track.voices do
        self._mixer:noteOff(track.voices[index].handle)
      end
    elseif mode == 3 then
      track.mute = 3
      releaseTrackVoices(self, track)
    end
  elseif op == "attack" then
    track.attack = resolveAmount(self, instruction.amount, instance)
  elseif op == "decay" then
    track.decay = resolveAmount(self, instruction.amount, instance)
  elseif op == "sustain" then
    track.sustain = resolveAmount(self, instruction.amount, instance)
  elseif op == "release" then
    track.release = resolveAmount(self, instruction.amount, instance)
  elseif op == "setvar" then
    varWrite(self, instance, instruction.var, resolveAmount(self, instruction.amount, instance))
  elseif op == "addvar" then
    varWrite(
      self,
      instance,
      instruction.var,
      varRead(self, instance, instruction.var) + resolveAmount(self, instruction.amount, instance)
    )
  elseif op == "subvar" then
    varWrite(
      self,
      instance,
      instruction.var,
      varRead(self, instance, instruction.var) - resolveAmount(self, instruction.amount, instance)
    )
  elseif op == "mulvar" then
    varWrite(
      self,
      instance,
      instruction.var,
      varRead(self, instance, instruction.var) * resolveAmount(self, instruction.amount, instance)
    )
  elseif op == "divvar" then
    -- The SDK skips the division by zero; the quotient truncates toward
    -- zero (C integer division, negative divisors included).
    local divisor = resolveAmount(self, instruction.amount, instance)
    if divisor ~= 0 then
      varWrite(self, instance, instruction.var, NnsSoundMath.cDiv(varRead(self, instance, instruction.var), divisor))
    end
  elseif op == "shiftvar" then
    -- A nonnegative shift moves left (wrapped to s16); a negative shift
    -- moves right (arithmetic).
    local shift = resolveAmount(self, instruction.amount, instance)
    local value = varRead(self, instance, instruction.var)
    if shift >= 0 then
      varWrite(self, instance, instruction.var, bit.lshift(value, shift))
    else
      varWrite(self, instance, instruction.var, bit.arshift(value, -shift))
    end
  elseif op == "randomvar" then
    -- The SDK maps the random draw into 0..|par| and negates for a
    -- negative par.
    local par = toS16(resolveAmount(self, instruction.amount, instance))
    local neg = par < 0
    local magnitude = neg and -par or par
    local random = math.floor(self._rng() * (magnitude + 1))
    varWrite(self, instance, instruction.var, neg and -random or random)
  elseif op == "cmp_eq" then
    track.cmp = varRead(self, instance, instruction.var) == toS16(resolveAmount(self, instruction.amount, instance))
  elseif op == "cmp_ne" then
    track.cmp = varRead(self, instance, instruction.var) ~= toS16(resolveAmount(self, instruction.amount, instance))
  elseif op == "cmp_gt" then
    track.cmp = varRead(self, instance, instruction.var) > toS16(resolveAmount(self, instruction.amount, instance))
  elseif op == "cmp_ge" then
    track.cmp = varRead(self, instance, instruction.var) >= toS16(resolveAmount(self, instruction.amount, instance))
  elseif op == "cmp_lt" then
    track.cmp = varRead(self, instance, instruction.var) < toS16(resolveAmount(self, instruction.amount, instance))
  elseif op == "cmp_le" then
    track.cmp = varRead(self, instance, instruction.var) <= toS16(resolveAmount(self, instruction.amount, instance))
  elseif op == "nop" then
    -- The reserved no-op opcodes of the corpus (0x82-0x8F, 0x90-0x92,
    -- 0x96-0x9F, 0xA3-0xAF, 0xB7, 0xBE-0xBF, 0xD8-0xDF, 0xE2, 0xE4-0xEF,
    -- 0xF0-0xFB, 0xFE): the SDK consumes them without effect.
  elseif
    op == "mod_depth"
    or op == "mod_speed"
    or op == "mod_type"
    or op == "mod_range"
    or op == "mod_delay"
    or op == "sweep"
    or op == "portamento_key"
    or op == "portamento"
    or op == "portamento_time"
  then
    -- Corpus-reachable commands whose effects this engine does not model
    -- (LFO modulation state, pitch sweep, portamento): the frozen
    -- vocabulary guarantees their shape; the engine accepts them without
    -- effect.
  elseif op == "loop_begin" then
    -- The frame carries the count and the return index (the instruction
    -- after the begin), mirroring the SDK's loopCount/posCallStack pair.
    track.loopStack[#track.loopStack + 1] = {
      remaining = resolveAmount(self, instruction.count, instance),
      returnIndex = track.pc + 1,
    }
  elseif op == "loop_end" then
    local frame = track.loopStack[#track.loopStack]
    if frame == nil then
      -- The SDK's 0xFC at call depth 0 is a no-op; the real corpus has
      -- tracks whose loop code is never entered (dead bytes), so an
      -- unmatched loop_end must never fault.
    elseif frame.remaining > 0 then
      frame.remaining = frame.remaining - 1
      if frame.remaining == 0 then
        table.remove(track.loopStack)
      else
        return frame.returnIndex
      end
    else
      -- Count 0 loops forever (the SDK's loopCount-0 branch; the real
      -- SEQ_GS_P_SAFARI_ROAD rings until the game stops it).
      return frame.returnIndex
    end
  else
    Errors.raise(AudioErrors.AUDIO_PLAYER_UNSUPPORTED_OP, "unsupported sequence instruction op", {
      op = op,
      pc = track.pc,
    })
  end
  return track.pc + 1
end

-- Executes instructions until the track is gated (waiting on a note or
-- wait) or ended, with a bounded step budget so a runaway non-gating
-- loop fails instead of hanging. A conditional instruction (the 0xA2 prefix)
-- executes only while the track comparison holds. A program counter past
-- the instruction list is a fall-through past the last instruction (a
-- top-level return, an SDK no-op): the track ends instead of reading
-- beyond the program.
local function fetch(self, instance, track)
  local steps = 0
  while not track.ended and not track.gated and not track.noteFinishWait do
    local instruction = instance.sequence.program.instructions[track.pc]
    if instruction == nil then
      track.ended = true
      break
    end
    if instruction.conditional and not track.cmp then
      track.pc = track.pc + 1
    else
      track.pc = execute(self, instance, track, instruction)
    end
    steps = steps + 1
    if steps > HOST_SAFETY_STEP_BUDGET then
      Errors.raise(
        AudioErrors.AUDIO_PLAYER_UNBOUNDED_EXECUTION,
        "sequence executed too many instructions without a wait",
        {
          playerId = instance.id,
        }
      )
    end
  end
end

local function releaseInstance(self, instance)
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      releaseTrackVoices(self, track)
    end
  end
end

-- Suspends or resumes every active voice of the instance in the mixer (the
-- transport pause: silent, sample positions frozen).
local function suspendInstance(self, instance, suspended)
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      for index = 1, #track.voices do
        self._mixer:suspendVoice(track.voices[index].handle, suspended)
      end
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
    -- The player-scoped RNG (injected or the deterministic default): plays
    -- share it and never reseed, so random operands stay reproducible.
    _rng = opts.rng or newRng(),
    -- The SDK shared global variables (vars 16..31); the player-local
    -- variables live on each instance.
    _globalVars = {},
    -- The total frames rendered; the mixer's control steps fire on the same
    -- absolute frame count, so the player's per-main pushes and release-end
    -- computations stay aligned with the mixer.
    _frameCount = 0,
    _controlPeriod = math.max(1, math.floor(opts.sampleRate / SOUND_INTERVAL)),
    -- False until the first play: the mixer's control cadence is frozen
    -- while nothing has ever been audible, so the phase a play sees starts
    -- at zero (idle frames before the first play never shift it). After the
    -- first play the mixer always renders, because released voices may be
    -- ringing even while no player instance is active.
    _everPlayed = false,
  }, SequencePlayer)
end

-- Starts `sequence` on its player id with `bank`. The bank must be the
-- sequence's bankId; a sequence already running on the same player id is
-- replaced (its voices released) exactly once, so the new note never mixes
-- with the old one. The entry track starts immediately (the SDK's
-- TrackStart): its program runs until the first gate, so a sequence
-- replaced before its first render has already allocated and released its
-- voices.
function SequencePlayer:play(sequence, bank)
  assert(sequence and bank, "play requires a sequence and a bank")
  if bank.id ~= sequence.bankId then
    Errors.raise(
      AudioErrors.AUDIO_PLAYER_BANK_MISMATCH,
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
  local instance = {
    id = playerId,
    sequence = sequence,
    bank = bank,
    channelMask = playerRecord.channelMask,
    tempo = DEFAULT_TEMPO,
    acc = 0,
    -- The player-level volume (the NNS player->volume): starts at the
    -- sequence's initial volume; master_volume commands change it.
    volume = sequence.player.initialVolume,
    -- The player-level fader (the NNS player fader NNS_SndPlayerMoveVolume
    -- drives): a volume-domain level, full by default; GameSound's fade
    -- state moves it and the control-step push delivers its dB-domain
    -- attenuation to the player's voices.
    fader = 127,
    -- The transport pause flag (NNS SND_PlayerPause): while paused the
    -- timeline freezes, no control values are pushed, and the voices are
    -- suspended in the mixer.
    paused = false,
    localVars = {},
    tracks = { [0] = newTrack(sequence.program.entry) },
  }
  self._players[playerId] = instance
  self._everPlayed = true
  fetch(self, instance, instance.tracks[0])
end

-- Sets the player's fader level (0..127, the volume domain -- the NNS
-- player fader NNS_SndPlayerMoveVolume drives). The attenuation reaches the
-- player's voices at the next control-step push as a dB-domain fader
-- (NnsSoundMath.decibelSquare; the mixer clamps at -0x8000). The GameSound
-- fade state is the caller; a player with no active instance is a no-op.
---@param playerId integer
---@param level integer
function SequencePlayer:setFader(playerId, level)
  assert(level >= 0 and level <= 127 and level % 1 == 0, "fader level must be an integer in 0..127")
  local instance = self._players[playerId]
  if instance == nil then
    return
  end
  instance.fader = level
end

-- Pauses the sequence on `playerId` (the NNS SND_PlayerPause transport
-- pause the HGSS PlayFanfare path uses): the instance stays held
-- (isPlayerPlaying stays true) but its tick timeline freezes, no control
-- values are pushed, and its voices suspend in the mixer -- silent, sample
-- position and envelope frozen in place. A player with no active instance,
-- or one already paused, is a no-op.
---@param playerId integer
function SequencePlayer:pausePlayer(playerId)
  local instance = self._players[playerId]
  if instance == nil or instance.paused then
    return
  end
  instance.paused = true
  suspendInstance(self, instance, true)
end

-- Resumes the paused sequence on `playerId`: the frozen timeline continues
-- and the suspended voices resume at their preserved positions. A player
-- with no active instance, or one not paused, is a no-op.
---@param playerId integer
function SequencePlayer:resumePlayer(playerId)
  local instance = self._players[playerId]
  if instance == nil or not instance.paused then
    return
  end
  instance.paused = false
  suspendInstance(self, instance, false)
end

-- Pushes the current track values to every active voice handle at the
-- player's main cadence (the NNS TrackUpdateChannel per main): the values
-- apply at the next mixer control step. The player fader rides the same
-- push as a dB-domain attenuation.
local function pushTrackValues(self, instance)
  local partial = { fader = NnsSoundMath.decibelSquare(instance.fader) }
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      partial.trackVolume = clamp(track.volume, 0, 127)
      partial.expression = clamp(track.expression, 0, 127)
      partial.playerVolume = clamp(instance.volume, 0, 127)
      partial.trackPanOffset = track.pan
      for index = 1, #track.voices do
        self._mixer:updateVoice(track.voices[index].handle, partial)
      end
    end
  end
end

-- Renders `frames` output frames of interleaved stereo int16 PCM. The
-- sequencer advances once per output frame: not-gated tracks fetch their
-- next instruction first, the per-main values push at the control-period
-- boundary, the mixer renders the frame, then each instance's tick
-- accumulator adds tempo*48 (a tick fires per sampleRate*60 units) and
-- every tick decrements each ringing voice's remaining length (releasing it
-- at zero, independently of gates) and each gated track's integer wait,
-- releasing completed gates and fetching the following instructions; the
-- note-finish hold counts down per frame. Players and tracks process
-- ascending over the fixed NNS domains. The mixer renders only while at
-- least one player is active, so idle frames never shift the control
-- cadence a later play sees. Per-frame processing with instance-carried
-- state keeps rendering independent of chunk size.
---@param frames integer
---@return integer[]
function SequencePlayer:render(frames)
  local out = {}
  for frame = 1, frames do
    local active = next(self._players) ~= nil or self._everPlayed
    if active then
      for playerId = 0, PLAYER_COUNT - 1 do
        local instance = self._players[playerId]
        if instance ~= nil and not instance.paused then
          for trackId = 0, TRACK_COUNT - 1 do
            local track = instance.tracks[trackId]
            if track ~= nil and not track.ended and not track.gated and not track.noteFinishWait then
              fetch(self, instance, track)
            end
          end
        end
      end
      if (self._frameCount + 1) % self._controlPeriod == 0 then
        for playerId = 0, PLAYER_COUNT - 1 do
          local instance = self._players[playerId]
          if instance ~= nil and not instance.paused then
            pushTrackValues(self, instance)
          end
        end
      end
      local pcm = self._mixer:render(1)
      out[#out + 1] = pcm[1]
      out[#out + 1] = pcm[2]
      for playerId = 0, PLAYER_COUNT - 1 do
        local instance = self._players[playerId]
        if instance ~= nil and not instance.paused then
          instance.acc = instance.acc + instance.tempo * 48
          while instance.acc >= self._sampleRate * 60 do
            instance.acc = instance.acc - self._sampleRate * 60
            for trackId = 0, TRACK_COUNT - 1 do
              local track = instance.tracks[trackId]
              if track ~= nil then
                -- Each voice's own length expires at its tick boundary:
                -- release it and drop it from the collection, in collection
                -- order. The zero-length note's release-end countdown
                -- starts at its expiry.
                local remaining = {}
                for index = 1, #track.voices do
                  local voice = track.voices[index]
                  voice.length = voice.length - 1
                  if voice.length <= 0 then
                    self._mixer:noteOff(voice.handle)
                    if voice.finishSteps ~= nil and track.finishWaitFrames == nil then
                      track.finishWaitFrames = framesToReleaseEnd(self, voice.finishSteps)
                    end
                  else
                    remaining[#remaining + 1] = voice
                  end
                end
                track.voices = remaining
              end
            end
            for trackId = 0, TRACK_COUNT - 1 do
              local track = instance.tracks[trackId]
              if track ~= nil and track.gated then
                track.wait = track.wait - 1
                if track.wait <= 0 then
                  track.gated = false
                  if not track.ended then
                    fetch(self, instance, track)
                  end
                end
              end
            end
          end
          for trackId = 0, TRACK_COUNT - 1 do
            local track = instance.tracks[trackId]
            if track ~= nil and track.noteFinishWait and track.finishWaitFrames ~= nil then
              track.finishWaitFrames = track.finishWaitFrames - 1
              if track.finishWaitFrames <= 0 then
                track.noteFinishWait = false
                track.finishWaitFrames = nil
              end
            end
          end
        end
      end
      self._frameCount = self._frameCount + 1
    else
      out[#out + 1] = 0
      out[#out + 1] = 0
    end
  end
  return out
end

-- Releases every voice of every active sequence and clears the players.
function SequencePlayer:stop()
  for playerId = 0, PLAYER_COUNT - 1 do
    local instance = self._players[playerId]
    if instance ~= nil then
      releaseInstance(self, instance)
    end
  end
  self._players = {}
end

-- Releases the voices of the sequence on `playerId` and removes it; a
-- player with no active instance is a no-op.
---@param playerId integer
function SequencePlayer:stopPlayer(playerId)
  local instance = self._players[playerId]
  if instance == nil then
    return
  end
  releaseInstance(self, instance)
  self._players[playerId] = nil
end

-- True while the sequence on `playerId` still has a running track; a player
-- whose sequence has ended (or was never started) reports free.
---@param playerId integer
---@return boolean
function SequencePlayer:isPlayerPlaying(playerId)
  local instance = self._players[playerId]
  if instance == nil then
    return false
  end
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil and not track.ended then
      return true
    end
  end
  return false
end

-- True while any track of any active sequence is still running.
function SequencePlayer:isPlaying()
  for playerId = 0, PLAYER_COUNT - 1 do
    local instance = self._players[playerId]
    if instance ~= nil then
      for trackId = 0, TRACK_COUNT - 1 do
        local track = instance.tracks[trackId]
        if track ~= nil and not track.ended then
          return true
        end
      end
    end
  end
  return false
end

return SequencePlayer
