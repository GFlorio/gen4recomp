-- Normalized semantic audio trace recorder for the conformance harness.
-- Collects the observer stream from SequencePlayer and VoiceMixer, normalizes
-- ordering, supports subset filtering, exact semantic comparison, and concise
-- mismatch diagnostics without collecting PCM payloads. Test data only, not a
-- public runtime API.

local AudioTrace = {}
AudioTrace.__index = AudioTrace

local PHASE_ORDER = {
  before_sequence = 1,
  after_sequence = 2,
  after_channels = 3,
}

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

local function sortedIntervals(intervals)
  local copy = {}
  for index, entry in ipairs(intervals) do
    copy[index] = entry
  end
  table.sort(copy, function(a, b)
    if a.ordinal ~= b.ordinal then
      return a.ordinal < b.ordinal
    end
    local ao = PHASE_ORDER[a.phase] or 99
    local bo = PHASE_ORDER[b.phase] or 99
    if ao ~= bo then
      return ao < bo
    end
    return a.phase < b.phase
  end)
  return copy
end

local function sortedBy(entries, comparator)
  local copy = {}
  for index, entry in ipairs(entries) do
    copy[index] = entry
  end
  table.sort(copy, comparator)
  return copy
end

function AudioTrace.new()
  return setmetatable({
    intervals = {},
    trackSteps = {},
    noteEvents = {},
    channelStates = {},
  }, AudioTrace)
end

function AudioTrace:clear()
  self.intervals = {}
  self.trackSteps = {}
  self.noteEvents = {}
  self.channelStates = {}
end

function AudioTrace:onSoundInterval(event)
  assert(type(event) == "table", "interval event must be a table")
  assert(type(event.ordinal) == "number", "interval ordinal must be a number")
  assert(type(event.phase) == "string", "interval phase must be a string")
  -- Store an immutable snapshot.
  self.intervals[#self.intervals + 1] = copyTable(event)
end

function AudioTrace:onTrackStep(event)
  assert(type(event) == "table", "track step must be a table")
  self.trackSteps[#self.trackSteps + 1] = copyTable(event)
end

function AudioTrace:onNoteEvent(event)
  assert(type(event) == "table", "note event must be a table")
  self.noteEvents[#self.noteEvents + 1] = copyTable(event)
end

function AudioTrace:onChannelState(event)
  assert(type(event) == "table", "channel state must be a table")
  self.channelStates[#self.channelStates + 1] = copyTable(event)
end

function AudioTrace:normalized()
  local out = AudioTrace.new()
  out.intervals = sortedIntervals(self.intervals)
  out.trackSteps = sortedBy(self.trackSteps, function(a, b)
    if a.ordinal ~= b.ordinal then
      return (a.ordinal or 0) < (b.ordinal or 0)
    end
    if a.playerId ~= b.playerId then
      return a.playerId < b.playerId
    end
    if a.trackSlot ~= b.trackSlot then
      return a.trackSlot < b.trackSlot
    end
    return (a.pc or 0) < (b.pc or 0)
  end)
  out.noteEvents = sortedBy(self.noteEvents, function(a, b)
    if a.playerId ~= b.playerId then
      return a.playerId < b.playerId
    end
    if a.trackSlot ~= b.trackSlot then
      return a.trackSlot < b.trackSlot
    end
    if a.key ~= b.key then
      return (a.key or 0) < (b.key or 0)
    end
    return false
  end)
  out.channelStates = sortedBy(self.channelStates, function(a, b)
    if a.channel ~= b.channel then
      return a.channel < b.channel
    end
    return (a.generation or 0) < (b.generation or 0)
  end)
  return out
end

function AudioTrace:filter(predicate)
  assert(type(predicate) == "table" or type(predicate) == "function", "filter requires a table or function")
  local out = AudioTrace.new()
  local function matches(entry)
    if type(predicate) == "function" then
      return predicate(entry)
    end
    for key, value in pairs(predicate) do
      if entry[key] ~= value then
        return false
      end
    end
    return true
  end

  for _, entry in ipairs(self.intervals) do
    if matches(entry) then
      out.intervals[#out.intervals + 1] = copyTable(entry)
    end
  end
  for _, entry in ipairs(self.trackSteps) do
    if matches(entry) then
      out.trackSteps[#out.trackSteps + 1] = copyTable(entry)
    end
  end
  for _, entry in ipairs(self.noteEvents) do
    if matches(entry) then
      out.noteEvents[#out.noteEvents + 1] = copyTable(entry)
    end
  end
  for _, entry in ipairs(self.channelStates) do
    if matches(entry) then
      out.channelStates[#out.channelStates + 1] = copyTable(entry)
    end
  end
  return out
end

local function scopedMatch(entry, field, value)
  return entry[field] == nil or entry[field] == value
end

function AudioTrace:filterByPlayer(playerId)
  return self:filter(function(entry)
    return scopedMatch(entry, "playerId", playerId)
  end)
end

function AudioTrace:filterByTrack(playerId, trackSlot)
  return self:filter(function(entry)
    if entry.playerId ~= nil and entry.playerId ~= playerId then
      return false
    end
    if entry.trackSlot ~= nil and entry.trackSlot ~= trackSlot then
      return false
    end
    return true
  end)
end

function AudioTrace:filterByChannel(channel)
  return self:filter(function(entry)
    return scopedMatch(entry, "channel", channel)
  end)
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

local function diffLists(name, expected, actual)
  if #expected ~= #actual then
    return string.format("%s count mismatch: expected %d got %d", name, #expected, #actual)
  end
  for index = 1, #expected do
    local exp = expected[index]
    local got = actual[index]
    if not shallowEqual(exp, got) then
      local function fmt(entry)
        local parts = {}
        for key, value in pairs(entry) do
          parts[#parts + 1] = string.format("%s=%s", tostring(key), tostring(value))
        end
        table.sort(parts)
        return "{" .. table.concat(parts, ", ") .. "}"
      end
      return string.format("%s mismatch at %d: expected %s got %s", name, index, fmt(exp), fmt(got))
    end
  end
  return nil
end

function AudioTrace:diagnostics(other)
  local a = self:normalized()
  local b = other:normalized()
  local checks = {
    { name = "intervals", expected = a.intervals, actual = b.intervals },
    { name = "trackSteps", expected = a.trackSteps, actual = b.trackSteps },
    { name = "noteEvents", expected = a.noteEvents, actual = b.noteEvents },
    { name = "channelStates", expected = a.channelStates, actual = b.channelStates },
  }
  local lines = {}
  for _, check in ipairs(checks) do
    local message = diffLists(check.name, check.expected, check.actual)
    if message ~= nil then
      lines[#lines + 1] = message
      -- Show first few entries for context.
      local limit = math.min(3, math.max(#check.expected, #check.actual))
      for index = 1, limit do
        local exp = check.expected[index]
        local got = check.actual[index]
        if exp ~= nil or got ~= nil then
          local function fmt(entry)
            if entry == nil then
              return "<missing>"
            end
            local parts = {}
            for key, value in pairs(entry) do
              parts[#parts + 1] = string.format("%s=%s", tostring(key), tostring(value))
            end
            table.sort(parts)
            return "{" .. table.concat(parts, ", ") .. "}"
          end
          lines[#lines + 1] = string.format("  [%d] expected %s", index, fmt(exp))
          lines[#lines + 1] = string.format("  [%d] actual   %s", index, fmt(got))
        end
      end
    end
  end
  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
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
    "intervals=%d trackSteps=%d noteEvents=%d channelStates=%d",
    #self.intervals,
    #self.trackSteps,
    #self.noteEvents,
    #self.channelStates
  )
end

return AudioTrace
