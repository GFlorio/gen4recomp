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
  local checks = {
    { name = "intervals", expected = self.intervals, actual = other.intervals },
    { name = "trackSteps", expected = self.trackSteps, actual = other.trackSteps },
    { name = "noteEvents", expected = self.noteEvents, actual = other.noteEvents },
    { name = "channelStates", expected = self.channelStates, actual = other.channelStates },
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
