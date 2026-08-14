-- Offline renderer for the three scoped Start Menu effects: plays a decoded
-- SSEQ event stream against a decoded SBNK and the SWAR archives its bank
-- references, producing 16-bit PCM. The shipped UI sequences use only a
-- small command subset: note-ons (velocity byte + var-length gate), rests,
-- tempo, program, pan/volume/expression/master-volume/pitch-bend/bend-range/
-- transpose, ADSR overrides, and the parameter events the player consumes
-- as state; every other event raises instead of being silently dropped
-- ("fail the build on an unsupported command"). The note byte is the
-- velocity; the pitch is the instrument entry's own note plus bend/transpose
-- (the effect banks are single-sample blips with dynamics automation).
-- Ticks convert through tempo * 48 ticks per minute (GBATEK's SSEQ timing),
-- and the render enforces a finite frame budget. Pure module.

local Errors = require("libs.errors.src.Errors")
local SwarDecoder = require("romdump.src.digest.SwarDecoder")

local SseqRenderer = {}

local MAX_STEPS = 100000
local MAX_SECONDS = 10

local function clamp(v, lo, hi)
  if v < lo then
    return lo
  end
  if v > hi then
    return hi
  end
  return v
end

local function firstTempo(sseq)
  for _, track in ipairs(sseq.tracks) do
    for _, event in ipairs(track.events) do
      if event.kind == "tempo" then
        return event.value
      end
    end
  end
  return 120
end

local function ticksToSeconds(ticks, tempo)
  return ticks * 60 / (tempo * 48)
end

local function resolveEntry(bank, program)
  local instrument = bank.instruments[program]
  if not instrument or instrument.kind == "unused" then
    Errors.raise("SND_INSTRUMENT_MISSING", "program " .. program .. " has no instrument", { program = program })
  end
  if instrument.kind == "direct" then
    return instrument.entry
  end
  if instrument.kind == "range" then
    -- The played pitch is the instrument's own note; use the lowest entry's
    -- sample and the highest entry's note as the root.
    local entries = instrument.entries
    local first, last
    for note, entry in pairs(entries) do
      if not first or note < first then
        first = note
      end
      if not last or note > last then
        last = note
      end
    end
    local entry = entries[first]
    return {
      swav = entry.swav,
      swar = entry.swar,
      note = entries[last].note,
      attack = entry.attack,
      decay = entry.decay,
      sustain = entry.sustain,
      release = entry.release,
      pan = entry.pan,
    }
  end
  -- The shipped UI banks resolve to their single swar; the region entry's
  -- swar reference falls back to the bank's first swar.
  local region = instrument.regions[#instrument.regions]
  if not region then
    Errors.raise("SND_INSTRUMENT_MISSING", "program " .. program .. " has no regions", { program = program })
  end
  return region.entry
end

local STATE_EVENTS = {
  volume = true,
  expression = true,
  master_volume = true,
  pan = true,
  pitch_bend = true,
  bend_range = true,
  transpose = true,
  program = true,
  attack = true,
  decay = true,
  sustain = true,
  release = true,
  loop_start = true,
  loop_end = true,
  jump = true,
  call = true,
  ["return"] = true,
  priority = true,
  mono = true,
  tie = true,
  portamento_control = true,
  mod_depth = true,
  mod_speed = true,
  mod_type = true,
  mod_range = true,
  portamento = true,
  portamento_time = true,
  print_variable = true,
  sweep_pitch = true,
  mod_delay = true,
  track_pointer = true,
  used_tracks = true,
}

local function renderInner(sseq, bank, swars)
  assert(sseq and sseq.tracks, "render requires a decoded SSEQ")
  assert(bank and bank.instruments, "render requires a decoded SBNK")
  local tempo = firstTempo(sseq)
  local rate = 32000
  local voices = {}
  local finishedFrames = 0

  for trackIndex, track in ipairs(sseq.tracks) do
    local events = track.events
    local pos = 1
    local tick = 0
    local volume = 127
    local expression = 127
    local masterVolume = 127
    local pan = 64
    local bend = 0
    local bendRange = 2
    local transpose = 0
    local program = 0
    local overrides = {}
    local loopStack = {}
    local steps = 0
    while pos <= #events do
      steps = steps + 1
      if steps > MAX_STEPS then
        Errors.raise("SND_SEQUENCE_UNBOUNDED", "track " .. (trackIndex - 1) .. " exceeds the step budget", {
          track = trackIndex - 1,
        })
      end
      local event = events[pos]
      pos = pos + 1
      local kind = event.kind
      if kind == "rest" then
        tick = tick + event.ticks
      elseif kind == "note" then
        local entry = resolveEntry(bank, program)
        local swar = swars[entry.swar + 1] or swars[1]
        local sample = swar and swar.samples[entry.swav]
        if not sample then
          Errors.raise("SND_SAMPLE_MISSING", "no sample " .. entry.swav .. " in the effect SWAR", {
            swav = entry.swav,
          })
        end
        rate = sample.sampleRate
        local semitones = transpose + bend * bendRange / 127
        local decoded, sampleErr = SwarDecoder.decodeSample(sample)
        if not decoded then
          error(sampleErr, 0)
        end
        voices[#voices + 1] = {
          startTick = tick,
          sample = decoded,
          rate = sample.sampleRate,
          factor = 2 ^ (semitones / 12),
          amplitude = clamp(volume * expression * masterVolume * event.velocity / (127 * 127 * 127), 0, 1),
          pan = pan,
          attack = overrides.attack or entry.attack,
          decay = overrides.decay or entry.decay,
          sustain = overrides.sustain or entry.sustain,
          release = overrides.release or entry.release,
        }
        tick = tick + event.gate
      elseif kind == "tempo" then
        tempo = event.value
      elseif kind == "end" then
        break
      elseif kind == "loop_start" then
        loopStack[#loopStack + 1] = { pos = pos, count = event.value }
      elseif kind == "loop_end" then
        local loop = loopStack[#loopStack]
        if loop then
          loop.count = loop.count - 1
          if loop.count > 0 then
            pos = loop.pos
          else
            loopStack[#loopStack] = nil
          end
        end
      elseif kind == "jump" then
        pos = event.target
      elseif kind == "call" then
        pos = event.target
      elseif STATE_EVENTS[kind] then
        if kind == "volume" then
          volume = event.value
        elseif kind == "expression" then
          expression = event.value
        elseif kind == "master_volume" then
          masterVolume = event.value
        elseif kind == "pan" then
          pan = event.value
        elseif kind == "pitch_bend" then
          bend = event.value - 64
        elseif kind == "bend_range" then
          bendRange = event.value
        elseif kind == "transpose" then
          transpose = event.value - 64
        elseif kind == "program" then
          program = event.program
        elseif kind == "attack" then
          overrides.attack = event.value
        elseif kind == "decay" then
          overrides.decay = event.value
        elseif kind == "sustain" then
          overrides.sustain = event.value
        elseif kind == "release" then
          overrides.release = event.value
        end
      else
        Errors.raise("SND_EVENT_UNSUPPORTED", "renderer cannot execute event " .. kind, { kind = kind })
      end
    end
    if tick > finishedFrames then
      finishedFrames = tick
    end
  end

  if finishedFrames <= 0 then
    Errors.raise("SND_SEQUENCE_EMPTY", "sequence renders no audio", {})
  end
  local seconds = ticksToSeconds(finishedFrames, tempo)
  if seconds > MAX_SECONDS then
    Errors.raise(
      "SND_SEQUENCE_UNBOUNDED",
      "sequence renders " .. seconds .. "s, beyond the " .. MAX_SECONDS .. "s budget",
      {
        seconds = seconds,
      }
    )
  end
  local frameCount = math.max(1, math.ceil(seconds * rate))

  local mix = {}
  for i = 1, frameCount do
    mix[i] = 0
  end
  for _, voice in ipairs(voices) do
    local startFrame = math.floor(ticksToSeconds(voice.startTick, tempo) * rate) + 1
    local frames = math.floor(#voice.sample / voice.factor)
    local envelope = 0
    local attackTicks = 255 - voice.attack
    local decayStep = voice.decay / 255 * 0.25
    local sustainLevel = voice.sustain / 127
    local releaseStep = voice.release / 255 * 0.25
    local releasing = false
    for i = 0, frames - 1 do
      local frame = startFrame + i
      if frame >= 1 and frame <= frameCount then
        local sampleIndex = math.floor(i * voice.factor) + 1
        local s = voice.sample[math.min(sampleIndex, #voice.sample)]
        if not releasing then
          if attackTicks <= 0 or envelope >= 1 then
            envelope = 1
            if sustainLevel < 1 and decayStep > 0 then
              envelope = math.max(sustainLevel, envelope - decayStep)
            end
          else
            envelope = envelope + (1 - envelope) * 0.5
          end
        else
          envelope = math.max(0, envelope - releaseStep)
        end
        local panGain = (voice.pan - 64) / 64 * 0.2
        mix[frame] = mix[frame] + s * envelope * voice.amplitude * (1 - math.abs(panGain)) * 0.6
      end
    end
  end
  local out = {}
  for i = 1, frameCount do
    local v = clamp(math.floor(mix[i]), -32768, 32767)
    out[i] = string.char(v % 256, math.floor(v / 256) % 256)
  end
  return { pcm16 = table.concat(out), sampleRate = rate, frameCount = frameCount }
end

---@param sseq { tracks: { events: table[] }[] }
---@param bank { instruments: table[] }
---@param swars table[]
---@return { pcm16: string, sampleRate: integer, frameCount: integer }?
---@return Errors.Error?
function SseqRenderer.render(sseq, bank, swars)
  local ok, result = pcall(renderInner, sseq, bank, swars)
  if ok then
    return result
  end
  if Errors.is(result) then
    return nil, result --[[@as Errors.Error]]
  end
  error(result)
end

return SseqRenderer
