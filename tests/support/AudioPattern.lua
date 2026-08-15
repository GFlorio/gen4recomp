-- Expected-PCM modeling shared by the audio suites: the release cadence the
-- VoiceMixer pins (one control step per CONTROL_PERIOD frames at 48 kHz; a
-- noteOff never kills the voice -- it rings at full gain to the next control
-- step, then RELEASE_TAIL frames at the release register gain, then
-- silence). The sequence-player and game-sound suites build their exact
-- expected vectors from these helpers, so the model lives in one place
-- instead of two copies that could drift from the mixer contract.

local AudioPattern = {}

-- Frames per tick at tempo 120 (sampleRate*60/(tempo*48)).
local FRAMES_PER_TICK = 500
local CONTROL_PERIOD = 250
local RELEASE_TAIL = 250
local RELEASE_TAIL_GAIN = 6 / 2048

-- The wave the voice reads at `frame`: the sample position advances by
-- `ratio` per frame from the note's first sounding frame.
---@param wave integer[]
---@param ratio number
---@param startFrame integer
---@param phaseOffset integer?
---@return fun(frame: integer): integer
function AudioPattern.waveAt(wave, ratio, startFrame, phaseOffset)
  phaseOffset = phaseOffset or 0
  return function(frame)
    local pos = (frame - startFrame) * ratio + phaseOffset
    return wave[math.floor(pos) % #wave + 1]
  end
end

-- The frames a note contributes, keyed by absolute frame: full gain through
-- its release point (`ticks` duration by default, or an explicit early
-- `releaseAt`), then full gain through the next control step (the release
-- lag), then RELEASE_TAIL frames at the release register gain, then silence.
-- The noteOff never kills the voice; the first release decrement fires at
-- the next control step and the voice stops on the following one.
---@param sampleAt fun(frame: integer): integer
---@param ticks integer
---@param startFrame integer
---@param frames integer
---@param releaseAt integer?
---@return table<integer, integer>
function AudioPattern.segment(sampleAt, ticks, startFrame, frames, releaseAt)
  releaseAt = releaseAt or startFrame + ticks * FRAMES_PER_TICK
  local nextStep = releaseAt + (CONTROL_PERIOD - (releaseAt % CONTROL_PERIOD))
  local out = {}
  for i = 1, frames do
    local frame = startFrame + i - 1
    if frame <= nextStep then
      out[frame] = sampleAt(frame)
    elseif frame <= nextStep + RELEASE_TAIL then
      out[frame] = math.floor(sampleAt(frame) * RELEASE_TAIL_GAIN + 0.5)
    else
      out[frame] = 0
    end
  end
  return out
end

-- A note's full segment in one call (the common no-early-release case).
---@param wave integer[]
---@param ratio number
---@param ticks integer
---@param startFrame integer
---@param frames integer
---@return table<integer, integer>
function AudioPattern.noteSegment(wave, ratio, ticks, startFrame, frames)
  return AudioPattern.segment(AudioPattern.waveAt(wave, ratio, startFrame), ticks, startFrame, frames)
end

-- Sums per-voice segments frame by frame (each voice is a mixer channel;
-- small amplitudes never saturate).
---@param segments table[]
---@param frames integer
---@return table<integer, integer>
function AudioPattern.sumSegments(segments, frames)
  local out = {}
  for frame = 1, frames do
    local value = 0
    for _, seg in ipairs(segments) do
      value = value + (seg[frame] or 0)
    end
    out[frame] = value
  end
  return out
end

-- The saturating variant for voices at full scale (the square rings at
-- +-32767, so the sum clamps at the int16 bounds exactly like the mixer).
---@param segments table[]
---@param frames integer
---@return table<integer, integer>
function AudioPattern.sumSegmentsSaturating(segments, frames)
  local out = {}
  for frame = 1, frames do
    local value = 0
    for _, seg in ipairs(segments) do
      value = value + (seg[frame] or 0)
    end
    if value > 32767 then
      value = 32767
    elseif value < -32768 then
      value = -32768
    end
    out[frame] = value
  end
  return out
end

-- Slices frames [from, to] of a summed pattern.
---@param pattern table<integer, integer>
---@param from integer
---@param to integer
---@return integer[]
function AudioPattern.slice(pattern, from, to)
  local out = {}
  for frame = from, to do
    out[#out + 1] = pattern[frame]
  end
  return out
end

return AudioPattern
