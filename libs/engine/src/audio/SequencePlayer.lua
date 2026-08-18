-- The g4 sequence-IR interpreter. It owns NNS-style players, active
-- sequences, tracks, program counters, track wait counters, call stacks,
-- loops, tempo, player variables, and track parameters, and drives a
-- VoiceMixer with the semantic voice spec ({channel, generation} handles,
-- trackVolume/playerVolume never folded, raw track pan offset, the clamped
-- transposed midiKey, the TrackInit userPitch 0, and the TrackPlayNote
-- sweep/LFO fields). It interprets project instruction IR, never SSEQ. The
-- tick clock is the NNS relationship verified from GBATEK ("DS Sound Files
-- - SSEQ") and the ARM7 NitroSDK player (SND_seq.c: SND_TIMER_RATE 240 at
-- the 192 Hz sound interval): a quarter note is 48 ticks and tempo is BPM
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
-- gate: the track stays blocked until its live channel handles are gone),
-- note-wait (default true), a polyphonic voice collection of {handle,
-- length} pairs (never a single channel), tie, mute, program, priority
-- (default 64), volume/expression 127, the raw pan offset (default 0; the
-- 0xC0 pan command stores amount-64), transpose, bend 0 (the SDK TrackInit;
-- bend is user pitch, never a key fold), bend range 2, the mod snapshot
-- (target 0, depth 0, range 1, speed 16, delay 0), sweepPitch 0,
-- portamentoKey 60, portamentoTime 0, the portamento flag, nullable
-- envelope stage overrides (0xD0-0xD3, applied to a note only when set),
-- and the call/loop stacks. Fresh tracks gate notes by their duration;
-- 0xC7 note_wait clears the flag so composers pair notes with explicit
-- 0x80 waits, and each ringing voice's own length bounds its ring
-- independently of gates (the NNS channel length): only positive finite
-- lengths are decremented toward release, while tied and non-positive-
-- duration channels are indefinite and never released by the duration
-- counter. WAIT 0 does not gate: the next instruction runs in the same
-- pass. Releases happen on open_track replacement, the tie command (which
-- always releases and frees the current voices, even when the flag value
-- is unchanged), mute mode 2/3, sequence replacement, and stop; a tied
-- note over an active voice reuses it in place (updateVoice key/velocity,
-- no noteOn, no noteOff). The mixer owns voice liveness (isVoiceAlive):
-- the player prunes stolen/dead handles from its collections and waits on
-- real handle liveness for note-finish, never on a predicted release end.
-- The transposed key is clamped to 0..127 before the bank leaf is selected
-- (AudioBank.selectVoice), so key-split and drum-set selection run on the
-- midi key, and pitch comes from the selected voice's root key. Loops
-- follow the ARM7 player (SND_seq.c): loop_begin pushes
-- a frame holding the count and the return index (the instruction after the
-- begin, the SDK's posCallStack); loop_end decrements and jumps back while
-- the count is positive, exits when it reaches zero, jumps forever while
-- the count is zero (the SDK's loopCount 0 -- the real SEQ_GS_P_SAFARI_ROAD),
-- and is a no-op with no active frame. A return with no active call is
-- likewise a no-op. Random amount operands resolve through the player's
-- injected or default RNG (created once at construction, never reseeded per
-- play) in the SDK u16 draw domain (SND_CalcRandom: state = state*1664525 +
-- 1013904223 mod 2^32, draw = state >> 16, initial state 0x12345678;
-- TrackParseValue scales min + ((draw * (max - min + 1)) >> 16)); variables
-- live in the SDK 16-local/16-global domain with s16
-- arithmetic (addvar/subvar/mulvar/divvar/shiftvar/randomvar, div-by-zero
-- skips, negative shifts shift right). The mod commands set the LFO
-- snapshot every noteOn spec carries and queue it to live voices; the
-- sweep/portamento commands set the note's TrackPlayNote sweep fields (the
-- track sweep plus the portamento contribution, and the sweep length
-- derived from portamentoTime), and each note updates the track's
-- portamento key to the note's MIDI key.
--
-- Rendering asks the mixer for spans that end at the next event boundary
-- (a tick that releases a gate, a note-finish clear, or the end of the
-- requested window) instead of one frame at a time, so command boundaries
-- inside a buffer still apply at their sample index, and the accumulator
-- and waits are instance/player state carried across render calls, so
-- chunk sizes never change the result. Players process
-- ascending player number and tracks ascending track number over the fixed
-- NNS domains (16 players x 16 tracks), so contested allocation is
-- deterministic. The mixer renders only while at least one player is
-- active, so the mixer's control cadence is aligned with a play (idle
-- frames before a play never shift the release phase). Control values
-- reach the active voices as events: a track/player control command
-- (volume, pan, expression, master volume, pitch bend, modulation) or a
-- fader change queues the current values -- including the user pitch and
-- the live LFO parameters -- to its live voice handles
-- immediately (the NNS TrackUpdateChannel delivery), and the mixer applies
-- them at its next control step -- the mixer owns the 192 Hz cadence, the
-- player maintains no second rounded control clock. play(sequence, bank)
-- starts the sequence on its player id and runs its entry program
-- immediately; the same player id replaces the running sequence (releasing
-- its voices), different player ids mix.

local Errors = require("libs.errors.src.Errors")
local AudioErrors = require("libs.engine.src.audio.AudioErrors")
local AudioBank = require("libs.assets.src.AudioBank")
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
-- The Nitro sound interval: 192 Hz global scheduling clock (spec §5.1)
local SOUND_INTERVAL_HZ = 192
-- The fixed NNS scheduling domains (SND_seq.c SND_PLAYER_COUNT /
-- SND_TRACK_COUNT): players and tracks iterate ascending over these bounds,
-- never in Lua table order, so contested allocation is deterministic.
local PLAYER_COUNT = 16
local TRACK_COUNT = 16
-- The Nitro sequence tick relationship at the 192 Hz sound interval:
-- SND_TIMER_RATE 240 (spec §5.3); per interval: tempoCounter is decremented
-- while >= 240, and incremented by tempoInc = (tempo * tempoRatio) >> 8.
local SND_TIMER_RATE = 240
-- The tick relationship (GBATEK "DS Sound Files - SSEQ" and the ARM7
-- SND_TIMER_RATE 240 at the 192 Hz sound interval): a quarter note is 48
-- ticks, so per output frame the accumulator gains tempo*TICKS_PER_QUARTER
-- and a tick fires each time it reaches sampleRate*SECONDS_PER_MINUTE.
local TICKS_PER_QUARTER = 48
local SECONDS_PER_MINUTE = 60
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

-- A deterministic default RNG matching SND_CalcRandom (SND_seq.c): state =
-- state * 1664525 + 1013904223 mod 2^32 (exact for every integer product,
-- which stays below 2^53 in the double domain), and the draw is the high
-- 16 bits of state, starting from 0x12345678. Created once per player at
-- construction; plays share it and never reseed.
local function newRng()
  local state = 0x12345678
  return function()
    state = (state * 1664525 + 1013904223) % 4294967296
    return math.floor(state / 65536)
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
-- value passes through, a random record draws from the player's RNG in the
-- SDK u16 draw domain and scales with the TrackParseValue integer
-- arithmetic (lo + arshift(draw * (hi - lo + 1), 16)), a variable record
-- reads the SDK variable it names. The sequence validator admits only these
-- shapes, so anything else is a programmer fault.
local function toS32(value)
  return bit.tobit(value)
end

local function randomOperand(draw, operand)
  local lo = operand.lo
  local hi = operand.hi
  local span = toS32(hi - lo + 1)
  local product = toS32(draw * span)
  return toS32(lo + bit.arshift(product, 16))
end

local function resolveAmount(self, amount, instance)
  if type(amount) == "number" then
    return amount
  end
  if amount.kind == "random" then
    -- Support both new lo/hi format (P2 changed) and legacy min/max for compatibility
    local draw = self._rng()
    if amount.lo ~= nil then
      return randomOperand(draw, amount)
    else
      -- Legacy format from pre-P2
      local span = amount.max - amount.min + 1
      return amount.min + math.floor(draw * span / 65536)
    end
  end
  if amount.kind == "variable" then
    return varRead(self, instance, assert(amount.var, "variable amount requires a var id"))
  end
  assert(false, "unsupported amount operand in sequence")
end

local function newTrack(entry)
  return {
    pc = entry,
    ended = false,
    gated = false,
    wait = 0,
    -- The note-finish hold: set by a zero-length note under note-wait; the
    -- track stays blocked until its live channel handles are gone.
    noteFinishWait = false,
    -- The track's ringing voices (polyphonic): a list of {handle, length}
    -- pairs -- the mixer {channel, generation} handle and the voice's
    -- remaining length in ticks (the NNS per-channel length, -1 for an
    -- indefinite tied or non-positive-duration voice), so a note never
    -- rings past its own duration into a later wait.
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
    -- The signed bend (the SDK TrackInit pitchBend 0; 0 is no bend, never
    -- a centered-at-64 convention): the pitch_bend command maps it to the
    -- voice's userPitch, never to a key change.
    bend = 0,
    bendRange = DEFAULT_BEND_RANGE,
    -- The LFO parameter snapshot (TrackInit via SND_InitLfoParam: target 0,
    -- depth 0, range 1, speed 16, delay 0); the mod commands set the fields
    -- and every noteOn spec carries a fresh copy.
    mod = { target = 0, depth = 0, range = 1, speed = 16, delay = 0 },
    -- The pitch-sweep/portamento state (TrackInit): the s16 sweepPitch, the
    -- portamento key/time pair and the portamento flag.
    sweepPitch = 0,
    portamentoKey = 60,
    portamentoTime = 0,
    portamento = false,
    -- Per-track envelope stage overrides (the NNS 0xD0-0xD3 commands), nil
    -- until set; a set override replaces exactly that stage of a note's
    -- envelope.
    attack = nil,
    decay = nil,
    sustain = nil,
    release = nil,
    callStack = {},
    loopStack = {},
  }
end

-- The SDK user pitch (SND_seq.c TrackUpdateChannel): pitchBend *
-- (bendRange << 6) >> 7 with arithmetic-shift (floor) semantics; bend 0 is
-- no bend.
local function userPitchFor(track)
  return math.floor(track.bend * (track.bendRange * 64) / 128)
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

-- Prunes the track's voice collection by mixer liveness: the mixer owns
-- voice death (a stolen channel, a completed one-shot, or the release-stop
-- step), so a handle it reports dead leaves the collection and a later
-- release or finish-wait check touches only the live voices. After the
-- call, `#track.voices` is the live count.
local function pruneTrackVoices(self, track)
  local write = 1
  local count = #track.voices
  for index = 1, count do
    local voice = track.voices[index]
    if self._mixer:isVoiceAlive(voice.handle) then
      track.voices[write] = voice
      write = write + 1
    end
  end
  for index = write, count do
    track.voices[index] = nil
  end
end

-- Starts the note's voice on the mixer and returns its {channel, generation}
-- handle (or nil for a silent note). `midiKey` is the already clamped
-- transposed key: it drives the bank leaf selection (SND_ReadInstData) and
-- rides the spec as the voice's key, and the pitch is the selected voice's
-- (midiKey - rootMidiKey) * 0x40 in the mixer -- never the source note key.
-- The voice spec carries the decoded PCM and loop window from the provider,
-- the raw track pan offset, the track/player priorities and channel mask
-- from the sequence's player record (nothing is folded into the track
-- volume), the TrackInit userPitch 0, the TrackPlayNote sweep fields (the
-- track sweep plus the portamento contribution, the sweep length from
-- portamentoTime, autoSweep, and the counter at 0) and a fresh
-- TrackUpdateChannel lfo snapshot of the track mod state.
local function startNote(self, instance, track, midiKey, velocity, length)
  -- A program the bank does not define is a silent note (the NNS
  -- SND_ReadInstData failure path): the real corpus references instruments
  -- whose SBNK records are unused/placeholder and the DS plays silence.
  local instrument = instance.bank.instruments[track.program]
  if instrument == nil then
    return nil
  end
  local voice = AudioBank.selectVoice(instrument, midiKey)
  if voice == nil then
    return nil
  end
  local spec = { generator = voice.generator }
  if voice.generator.kind == "sample" then
    local sample = self._provider:loadSample(voice.generator.sample)
    spec.baseTimer = sample.metadata.baseTimer
    spec.pcm = sample.pcm
    spec.loop = sample.metadata.loop
    spec.loopEnabled = sample.metadata.loopEnabled
  end
  local sequence = instance.sequence
  spec.originalKey = voice.originalKey
  spec.key = midiKey
  -- The TrackInit user pitch (SND_seq.c TrackInit pitchBend 0, mapped to
  -- the voice by TrackUpdateChannel): bend 0 is no bend.
  spec.userPitch = userPitchFor(track)
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
  -- TrackPlayNote: the sweep starts from the track sweepPitch; a note under
  -- portamento adds (portamentoKey - midiKey) << 6 units (the sums stay in
  -- the s16 domain). With no portamento time the sweep length is the note
  -- length and the sweep does not advance on its own; with one it is
  -- time^2 * |sweepPitch| >> 11 and the mixer advances it per control step.
  spec.sweepPitch = track.sweepPitch
  if track.portamento then
    spec.sweepPitch = toS16(spec.sweepPitch + (track.portamentoKey - midiKey) * 64)
  end
  if track.portamentoTime == 0 then
    spec.sweepLength = length
    spec.autoSweep = false
  else
    local magnitude = spec.sweepPitch < 0 and -spec.sweepPitch or spec.sweepPitch
    spec.sweepLength = math.floor(track.portamentoTime * track.portamentoTime * magnitude / 2048)
    spec.autoSweep = true
  end
  spec.sweepCounter = 0
  spec.lfo = {
    target = track.mod.target,
    depth = track.mod.depth,
    range = track.mod.range,
    speed = track.mod.speed,
    delay = track.mod.delay,
  }
  return self._mixer:noteOn(spec)
end

-- Releases every live voice handle of a track (a soft release; each voice
-- rings out its release tail) and clears the collection. Dead handles are
-- pruned first, so a stale handle never gets a release. `releaseOverride`
-- (nil or an integer 0..127) is passed to the mixer noteOffs -- the forced
-- track-release path the transport pause uses.
local function releaseTrackVoices(self, track, releaseOverride)
  pruneTrackVoices(self, track)
  for index = 1, #track.voices do
    self._mixer:noteOff(track.voices[index].handle, releaseOverride)
  end
  track.voices = {}
end

-- Queues the current track values to every live voice handle of a track
-- (the NNS TrackUpdateChannel delivery): a track/player control command or
-- a fader change delivers the current values as an event immediately, and
-- the mixer applies them at its next control step -- the mixer owns the
-- 192 Hz cadence, the player never rounds it. New notes already receive
-- the current values in their noteOn spec. The partial carries the user
-- pitch and the track's live LFO parameter table, so later modulation
-- commands change the values the mixer applies.
local function pushTrackValues(self, instance, track)
  local partial = {
    trackVolume = clamp(track.volume, 0, 127),
    expression = clamp(track.expression, 0, 127),
    playerVolume = clamp(instance.volume, 0, 127),
    trackPanOffset = track.pan,
    userPitch = userPitchFor(track),
    lfo = track.mod,
    -- The player fader rides the same queue as a dB-domain attenuation.
    fader = NnsSoundMath.decibelSquare(instance.fader),
  }
  for index = 1, #track.voices do
    self._mixer:updateVoice(track.voices[index].handle, partial)
  end
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
    -- length bounds its ring independently. The transposed key is clamped
    -- to the MIDI domain BEFORE the bank leaf is selected (SND_seq.c
    -- TrackStepTicks midiKey + TrackPlayNote SND_ReadInstData), so
    -- key-split and drum-set selection run on the midi key and the spec
    -- key is that clamped key. A note's channel length is its finite
    -- duration when positive; tied starts and non-positive durations are
    -- indefinite (the SDK -1) and are never released by the duration
    -- counter. A zero-length note under note-wait is a note-FINISH wait
    -- (the NNS noteFinishWait), not a one-tick gate: the track stays
    -- blocked until its live channel handles are gone. Muted tracks play
    -- no voice but gate exactly like normal notes.
    local length = resolveAmount(self, instruction.duration, instance)
    local midiKey = clamp(instruction.key + track.transpose, 0, 127)
    if track.mute == 0 then
      if track.tie then
        -- Tied re-note: reuse the most recent live voice in place (the NNS
        -- TrackPlayNote tie path): no noteOn, no noteOff; the key and
        -- velocity change at the next control step and the envelope never
        -- restarts. The reused head keeps its indefinite length. Without a
        -- live voice a fresh tied channel starts, also indefinite.
        pruneTrackVoices(self, track)
        if #track.voices > 0 then
          local head = track.voices[#track.voices]
          self._mixer:updateVoice(head.handle, {
            key = midiKey,
            velocity = instruction.velocity,
          })
        else
          local handle = startNote(self, instance, track, midiKey, instruction.velocity, length)
          if handle ~= nil then
            track.voices[#track.voices + 1] = { handle = handle, length = -1 }
          end
        end
      else
        local handle = startNote(self, instance, track, midiKey, instruction.velocity, length)
        if handle ~= nil then
          track.voices[#track.voices + 1] = { handle = handle, length = length > 0 and length or -1 }
        end
      end
    end
    -- TrackPlayNote ends by storing the played MIDI key as the track's
    -- portamento key, so the next note's portamento contribution slides
    -- from the just-played pitch.
    track.portamentoKey = midiKey
    if track.noteWait then
      track.gated = true
      track.wait = length
      if length == 0 then
        track.noteFinishWait = true
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
    pushTrackValues(self, instance, track)
  elseif op == "volume" then
    track.volume = resolveAmount(self, instruction.amount, instance)
    pushTrackValues(self, instance, track)
  elseif op == "master_volume" then
    -- 0xC2 is the PLAYER volume: it changes every voice of the player.
    instance.volume = resolveAmount(self, instruction.amount, instance)
    for trackId = 0, TRACK_COUNT - 1 do
      local track = instance.tracks[trackId]
      if track ~= nil then
        pushTrackValues(self, instance, track)
      end
    end
  elseif op == "expression" then
    track.expression = resolveAmount(self, instruction.amount, instance)
    pushTrackValues(self, instance, track)
  elseif op == "transpose" then
    track.transpose = resolveAmount(self, instruction.amount, instance)
  elseif op == "pitch_bend" then
    -- The signed bend maps to the voice's user pitch (never a key change);
    -- a change reaches the active voices as a queued userPitch partial.
    track.bend = resolveAmount(self, instruction.amount, instance)
    pushTrackValues(self, instance, track)
  elseif op == "pitch_bend_range" then
    track.bendRange = resolveAmount(self, instruction.amount, instance)
  elseif op == "note_wait" then
    -- 0xC7 sets/clears the note-gating flag (u8, nonzero = set).
    track.noteWait = resolveAmount(self, instruction.amount, instance) ~= 0
  elseif op == "priority" then
    track.priority = resolveAmount(self, instruction.amount, instance)
  elseif op == "tie" then
    -- 0xC8: the tie command always releases and frees the track's current
    -- voices, even when the new flag equals the previous flag (SND_seq.c:
    -- TrackReleaseChannels + TrackFreeChannels after setting the flag); a
    -- tied note over an active voice reuses it.
    track.tie = resolveAmount(self, instruction.amount, instance) ~= 0
    releaseTrackVoices(self, track)
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
    -- The SDK maps the u16 random draw into 0..|par| with the TrackParseValue
    -- integer scaling and negates for a negative par.
    local par = toS16(resolveAmount(self, instruction.amount, instance))
    local neg = par < 0
    local magnitude = neg and -par or par
    local random = math.floor(self._rng() * (magnitude + 1) / 65536)
    varWrite(self, instance, instruction.var, neg and -random or random)
  elseif op == "nop" then
    -- The reserved no-op opcodes of the corpus (0x82-0x8F, 0x90-0x92,
    -- 0x96-0x9F, 0xA3-0xAF, 0xB7, 0xBE-0xBF, 0xD8-0xDF, 0xE2, 0xE4-0xEF,
    -- 0xF0-0xFB, 0xFE): the SDK consumes them without effect.
  elseif op == "mod_depth" then
    -- 0xCA-0xCD/0xE0: the mod fields are u8/u16 binary values stored as
    -- their C types, so out-of-domain amounts wrap. A change reaches the
    -- active voices as a queued partial carrying the live LFO parameters.
    track.mod.depth = resolveAmount(self, instruction.amount, instance) % 256
    pushTrackValues(self, instance, track)
  elseif op == "mod_speed" then
    track.mod.speed = resolveAmount(self, instruction.amount, instance) % 256
    pushTrackValues(self, instance, track)
  elseif op == "mod_type" then
    track.mod.target = resolveAmount(self, instruction.amount, instance) % 256
    pushTrackValues(self, instance, track)
  elseif op == "mod_range" then
    track.mod.range = resolveAmount(self, instruction.amount, instance) % 256
    pushTrackValues(self, instance, track)
  elseif op == "mod_delay" then
    track.mod.delay = resolveAmount(self, instruction.amount, instance) % 65536
    pushTrackValues(self, instance, track)
  elseif op == "sweep" then
    -- 0xE3: the s16 track sweep pitch.
    track.sweepPitch = toS16(resolveAmount(self, instruction.amount, instance))
  elseif op == "portamento_key" then
    -- 0xC9: stores the u8 key plus transpose and sets the portamento flag.
    track.portamentoKey = (resolveAmount(self, instruction.amount, instance) + track.transpose) % 256
    track.portamento = true
  elseif op == "portamento" then
    -- 0xCE: the flag is the operand's truthiness.
    track.portamento = resolveAmount(self, instruction.amount, instance) ~= 0
  elseif op == "portamento_time" then
    -- 0xCF: the u8 sweep time.
    track.portamentoTime = resolveAmount(self, instruction.amount, instance) % 256
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
    -- The sequence validator admits only the ops above, so an unknown op is
    -- a programmer fault, never a silent no-op.
    assert(false, "unsupported sequence instruction op " .. tostring(op) .. " at pc " .. tostring(track.pc))
  end
  return track.pc + 1
end

-- Executes instructions until the track is gated (waiting on a note or
-- wait) or ended, with a bounded step budget so a runaway non-gating
-- loop fails instead of hanging. A program counter past the instruction
-- list is a fall-through past the last instruction (a top-level return, an
-- SDK no-op): the track ends instead of reading beyond the program.
local function fetch(self, instance, track)
  local steps = 0
  while not track.ended and not track.gated and not track.noteFinishWait do
    local instruction = instance.sequence.program.instructions[track.pc]
    if instruction == nil then
      track.ended = true
      break
    end
    track.pc = execute(self, instance, track, instruction)
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
    -- The global 192 Hz sound phase accumulator (spec §5.1): each rendered
    -- frame advances phase by SOUND_INTERVAL_HZ units. When phase >= sampleRate,
    -- a sound interval fires and phase is decremented by sampleRate.
    _soundPhase = 0,
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
    tempoRatio = 256,
    tempoCounter = 240,
    acc = 0,
    -- Entry program fetched on first 192 Hz boundary after play(), not immediately
    entryFetched = false,
    -- The player-level volume (the NNS player->volume): starts at the
    -- sequence's initial volume; master_volume commands change it.
    volume = sequence.player.initialVolume,
    -- The player-level fader (the NNS player fader NNS_SndPlayerMoveVolume
    -- drives): a volume-domain level, full by default; GameSound's fade
    -- state moves it and the control-step push delivers its dB-domain
    -- attenuation to the player's voices.
    fader = 127,
    -- The transport pause flag (NNS SND_PlayerPause): while paused the
    -- timeline freezes and no control values are pushed; the pause release
    -- already freed the channels.
    paused = false,
    localVars = {},
    tracks = { [0] = newTrack(sequence.program.entry) },
  }
  self._players[playerId] = instance
  self._everPlayed = true
end

-- Sets the player's fader level (0..127, the volume domain -- the NNS
-- player fader NNS_SndPlayerMoveVolume drives). The attenuation reaches the
-- player's voices immediately as a queued dB-domain fader event
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
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      pushTrackValues(self, instance, track)
    end
  end
end

-- Pauses the sequence on `playerId` (the NNS SND_PlayerPause transport
-- pause the HGSS PlayFanfare path uses): the instance stays held
-- (isPlayerPlaying stays true) but its tick timeline freezes, no control
-- values are pushed, and the player's current track channels are released
-- with the forced release override 127 and freed from the tracks -- the
-- SDK pause releases and frees channels, preserving no sample or envelope
-- state for resumption. A player with no active instance, or one already
-- paused, is a no-op.
---@param playerId integer
function SequencePlayer:pausePlayer(playerId)
  local instance = self._players[playerId]
  if instance == nil or instance.paused then
    return
  end
  instance.paused = true
  for trackId = 0, TRACK_COUNT - 1 do
    local track = instance.tracks[trackId]
    if track ~= nil then
      releaseTrackVoices(self, track, 127)
    end
  end
end

-- Resumes the paused sequence on `playerId`: the frozen timeline continues
-- from its paused position. The channels released at pause are not
-- resurrected -- their handles are gone from the tracks. A player with no
-- active instance, or one not paused, is a no-op.
---@param playerId integer
function SequencePlayer:resumePlayer(playerId)
  local instance = self._players[playerId]
  if instance == nil or not instance.paused then
    return
  end
  instance.paused = false
end

-- Processes one 192 Hz sound interval: advances entry-program fetching
-- for freshly played sequences on their first interval boundary.
local function processSoundInterval(self)
  for playerId = 0, PLAYER_COUNT - 1 do
    local instance = self._players[playerId]
    if instance ~= nil and not instance.entryFetched then
      instance.entryFetched = true
      local track = instance.tracks[0]
      if track ~= nil then
        fetch(self, instance, track)
      end
    end
  end
end

-- The frames until the next event boundary from the current position: the
-- span of output frames the mixer can render in one call without breaking
-- the per-frame delivery order. Every tick-issued event -- a voice expiry
-- noteOff, a released gate's following notes -- lands in the frame loop
-- after the span's render, so the span ends on the next tick of any active
-- instance and the events reach the mixer before the next span, at the
-- same absolute frames whatever the chunk sizes. The end of the requested
-- window is always a boundary.
local function spanLength(self, remaining)
  local span = remaining
  for playerId = 0, PLAYER_COUNT - 1 do
    local instance = self._players[playerId]
    if instance ~= nil and not instance.paused then
      local ticksPerFrame = instance.tempo * TICKS_PER_QUARTER
      if ticksPerFrame > 0 then
        local framesToTick = math.ceil((self._sampleRate * SECONDS_PER_MINUTE - instance.acc) / ticksPerFrame)
        if framesToTick <= span then
          span = math.min(span, framesToTick)
        end
      end
    end
  end
  return span
end

-- Renders `frames` output frames of interleaved stereo int16 PCM. The
-- sequencer advances once per output frame: not-gated tracks fetch their
-- next instruction first, the mixer renders the span, then each frame the
-- note-finish holds are checked against real handle liveness and each
-- instance's tick accumulator adds tempo*48 (a tick fires per sampleRate*60
-- units). Every tick prunes dead handles, decrements each ringing voice's
-- remaining length (releasing it at zero, independently of gates) and each
-- gated track's integer wait, releasing completed gates and fetching the
-- following instructions. The mixer renders in spans that end at the next
-- event boundary (spanLength) instead of one frame at a time, preserving
-- the per-frame delivery order of note-offs and gate-release notes without
-- a mixer call per frame. Players and tracks process ascending over the
-- fixed NNS domains. The mixer renders only while at least one player is
-- active, so idle frames never shift the control cadence a later play
-- sees. Instance-carried state keeps rendering independent of chunk size.
---@param frames integer
---@return integer[]
function SequencePlayer:render(frames)
  local out = {}
  local remaining = frames
  while remaining > 0 do
    if not (next(self._players) ~= nil or self._everPlayed) then
      for i = 1, remaining * 2 do
        out[#out + 1] = 0
      end
      break
    end
    for playerId = 0, PLAYER_COUNT - 1 do
      local instance = self._players[playerId]
      if instance ~= nil and not instance.paused then
        for trackId = 0, TRACK_COUNT - 1 do
          local track = instance.tracks[trackId]
          -- Skip fetching from track 0 until entry program has been fetched at first 192 Hz boundary
          if track ~= nil and not track.ended and not track.gated and not track.noteFinishWait then
            if trackId == 0 and not instance.entryFetched then
              -- Defer entry program to first 192 Hz boundary
            else
              fetch(self, instance, track)
            end
          end
        end
      end
    end
    local span = spanLength(self, remaining)
    assert(span >= 1, "a render span must advance the frame count")
    self._mixer:renderInto(out, span)
    for frame = 1, span do
      -- Advance the global 192 Hz sound phase (spec §5.1): each frame adds
      -- SOUND_INTERVAL_HZ units to phase; a boundary fires when phase >= sampleRate.
      self._soundPhase = self._soundPhase + SOUND_INTERVAL_HZ
      local soundIntervalFired = false
      if self._soundPhase >= self._sampleRate then
        self._soundPhase = self._soundPhase - self._sampleRate
        soundIntervalFired = true
        processSoundInterval(self)
      end

      for playerId = 0, PLAYER_COUNT - 1 do
        local instance = self._players[playerId]
        if instance ~= nil and not instance.paused then
          -- The note-finish hold clears on the first frame after its
          -- zero-length note's gate opened whose live handles are all gone
          -- (SND_seq.c TrackStepTicks: the note_finish_wait check runs per
          -- tick over the track's channel list; the wait clears when the
          -- list is empty and the track resumes). The resumed track
          -- fetches its following instructions here.
          for trackId = 0, TRACK_COUNT - 1 do
            local track = instance.tracks[trackId]
            if track ~= nil and track.noteFinishWait and not track.gated then
              pruneTrackVoices(self, track)
              if #track.voices == 0 then
                track.noteFinishWait = false
                fetch(self, instance, track)
              end
            end
          end
          instance.acc = instance.acc + instance.tempo * TICKS_PER_QUARTER
          while instance.acc >= self._sampleRate * SECONDS_PER_MINUTE do
            instance.acc = instance.acc - self._sampleRate * SECONDS_PER_MINUTE
            for trackId = 0, TRACK_COUNT - 1 do
              local track = instance.tracks[trackId]
              if track ~= nil then
                -- Dead/stolen handles leave the collection first, so a
                -- release or a later note never touches a stale handle.
                pruneTrackVoices(self, track)
                -- Each voice's own length expires at its tick boundary (the
                -- NNS channel length): only positive finite lengths
                -- decrement, and an expired voice is released and dropped
                -- from the collection. Tied and non-positive-length voices
                -- are indefinite and are never released by the counter.
                local write = 1
                local count = #track.voices
                for index = 1, count do
                  local voice = track.voices[index]
                  if voice.length > 0 then
                    voice.length = voice.length - 1
                    if voice.length > 0 then
                      track.voices[write] = voice
                      write = write + 1
                    else
                      self._mixer:noteOff(voice.handle)
                    end
                  else
                    track.voices[write] = voice
                    write = write + 1
                  end
                end
                for index = write, count do
                  track.voices[index] = nil
                end
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
        end
      end
    end
    remaining = remaining - span
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
