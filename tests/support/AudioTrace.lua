-- Chronological semantic audio trace recorder for the conformance harness.
-- Collects the observer stream from SequencePlayer and VoiceMixer in callback
-- order, supports exact semantic comparison, and reports concise mismatches
-- without collecting PCM payloads. Test data only, not a public runtime API.

local AudioTrace = {}
AudioTrace.__index = AudioTrace

local function copyTable(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, field in pairs(value) do
    out[key] = field
  end
  return out
end

function AudioTrace.new()
  return setmetatable({
    events = {},
    intervals = {},
    trackSteps = {},
    noteEvents = {},
    channelStates = {},
  }, AudioTrace)
end

function AudioTrace:clear()
  self.events = {}
  self.intervals = {}
  self.trackSteps = {}
  self.noteEvents = {}
  self.channelStates = {}
end

local function appendEvent(self, kind, category, event)
  local snapshot = copyTable(event)
  category[#category + 1] = snapshot
  self.events[#self.events + 1] = { kind = kind, event = snapshot }
end

function AudioTrace:onSoundInterval(event)
  assert(type(event) == "table", "interval event must be a table")
  assert(type(event.ordinal) == "number", "interval ordinal must be a number")
  assert(type(event.phase) == "string", "interval phase must be a string")
  appendEvent(self, "sound_interval", self.intervals, event)
end

function AudioTrace:onTrackStep(event)
  assert(type(event) == "table", "track step must be a table")
  appendEvent(self, "track_step", self.trackSteps, event)
end

function AudioTrace:onNoteEvent(event)
  assert(type(event) == "table", "note event must be a table")
  appendEvent(self, "note_event", self.noteEvents, event)
end

function AudioTrace:onChannelState(event)
  assert(type(event) == "table", "channel state must be a table")
  appendEvent(self, "channel_state", self.channelStates, event)
end

local function shallowEqual(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for key, value in pairs(a) do
    if b[key] ~= value then
      return false
    end
  end
  for key in pairs(b) do
    if a[key] == nil then
      return false
    end
  end
  return true
end

local function formatValue(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local parts = {}
  for key, field in pairs(value) do
    parts[#parts + 1] = string.format("%s=%s", tostring(key), formatValue(field))
  end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function diffEvents(expected, actual)
  if #expected ~= #actual then
    return string.format("global event count mismatch: expected %d got %d", #expected, #actual)
  end
  for index = 1, #expected do
    local exp = expected[index]
    local got = actual[index]
    if exp.kind ~= got.kind or not shallowEqual(exp.event, got.event) then
      return string.format("global event %d mismatch: expected %s got %s", index, formatValue(exp), formatValue(got))
    end
  end
  return nil
end

function AudioTrace:diagnostics(other)
  return diffEvents(self.events, other.events)
end

function AudioTrace:equals(other)
  return self:diagnostics(other) == nil
end

function AudioTrace:intervalPhases(ordinal)
  local phases = {}
  for _, interval in ipairs(self.intervals) do
    if ordinal == nil or interval.ordinal == ordinal then
      phases[#phases + 1] = interval.phase
    end
  end
  return phases
end

function AudioTrace:summary()
  return string.format(
    "events=%d intervals=%d trackSteps=%d noteEvents=%d channelStates=%d",
    #self.events,
    #self.intervals,
    #self.trackSteps,
    #self.noteEvents,
    #self.channelStates
  )
end

return AudioTrace
