-- PosePerformanceCounter: the pose/material evaluation counters of the
-- animation runtime (spec section 39). Each record accumulates call counts
-- and elapsed seconds for one phase of the pose pipeline, keyed by an
-- arbitrary key -- the scene loader and ModelInstance use the instance table
-- itself, so every placement gets its own row -- while per-phase totals give
-- the per-scene view. The clock is injectable (default os.clock) so timing
-- tests stay deterministic. Pure domain module; the caller decides what to
-- measure (the loader measures scene passes, ModelInstance measures its pose
-- and material evaluations).

local PosePerformanceCounter = {}
PosePerformanceCounter.__index = PosePerformanceCounter

-- The measured phases of the animation path:
--   pose      one full pose evaluation (PoseBackend.evaluate)
--   material  one material-state evaluation (MaterialEvaluator)
--   update    one fixed-step attachment advance
--   bandSwap  one time-of-day band swap (stop + play)
--   sync      one scene draw/update pass (scene-level; key is nil)
PosePerformanceCounter.POSE = "pose"
PosePerformanceCounter.MATERIAL = "material"
PosePerformanceCounter.UPDATE = "update"
PosePerformanceCounter.BAND_SWAP = "bandSwap"
PosePerformanceCounter.SYNC = "sync"

local PHASES = {
  [PosePerformanceCounter.POSE] = true,
  [PosePerformanceCounter.MATERIAL] = true,
  [PosePerformanceCounter.UPDATE] = true,
  [PosePerformanceCounter.BAND_SWAP] = true,
  [PosePerformanceCounter.SYNC] = true,
}

---@class PosePerformanceCounter
---@field clock fun(): number
---@field rows table -- [key][phase] = { count, seconds }
---@field totals table -- [phase] = { count, seconds }

-- opts.clock replaces the default os.clock (tests inject a sequence).
function PosePerformanceCounter.new(opts)
  opts = opts or {}
  assert(type(opts.clock) == "function" or opts.clock == nil, "clock must be a function")
  return setmetatable({
    clock = opts.clock or os.clock,
    rows = {},
    totals = {},
  }, PosePerformanceCounter)
end

-- Accumulate one phase measurement for `key` (nil accumulates only the
-- per-scene total). `seconds` is the phase's elapsed time.
function PosePerformanceCounter:record(key, phase, seconds)
  assert(PHASES[phase], "unknown pose-performance phase " .. tostring(phase))
  assert(type(seconds) == "number" and seconds >= 0, "elapsed seconds must be non-negative")
  local total = self.totals[phase] or { count = 0, seconds = 0 }
  total.count = total.count + 1
  total.seconds = total.seconds + seconds
  self.totals[phase] = total
  if key ~= nil then
    local row = self.rows[key] or {}
    local cell = row[phase] or { count = 0, seconds = 0 }
    cell.count = cell.count + 1
    cell.seconds = cell.seconds + seconds
    row[phase] = cell
    self.rows[key] = row
  end
end

-- Run `fn` under the clock, recording one measurement for (key, phase).
-- Returns fn's result; a raised error propagates unrecorded.
function PosePerformanceCounter:measure(key, phase, fn)
  assert(PHASES[phase], "unknown pose-performance phase " .. tostring(phase))
  local t0 = self.clock()
  local result = fn()
  self:record(key, phase, self.clock() - t0)
  return result
end

-- The call count for (key, phase); key nil reads the per-scene total.
---@return integer
function PosePerformanceCounter:count(key, phase)
  assert(PHASES[phase], "unknown pose-performance phase " .. tostring(phase))
  if key == nil then
    local total = self.totals[phase]
    return total and total.count or 0
  end
  local cell = self.rows[key] and self.rows[key][phase]
  return cell and cell.count or 0
end

-- The accumulated seconds for (key, phase); key nil reads the scene total.
---@return number
function PosePerformanceCounter:seconds(key, phase)
  assert(PHASES[phase], "unknown pose-performance phase " .. tostring(phase))
  if key == nil then
    local total = self.totals[phase]
    return total and total.seconds or 0
  end
  local cell = self.rows[key] and self.rows[key][phase]
  return cell and cell.seconds or 0
end

-- Every keyed row, sorted by key then phase: { key, phase, count, seconds }.
-- `nameOf` renders non-string keys (the loader passes the instance's model
-- and placement); without one, non-string keys render as tostring.
---@param nameOf? fun(key: any): string
---@return { key: string, phase: string, count: integer, seconds: number }[]
function PosePerformanceCounter:summary(nameOf)
  local out = {}
  for key, row in pairs(self.rows) do
    local label = type(key) == "string" and key or nameOf and nameOf(key) or tostring(key)
    for phase, cell in pairs(row) do
      out[#out + 1] = { key = label, phase = phase, count = cell.count, seconds = cell.seconds }
    end
  end
  table.sort(out, function(a, b)
    if a.key ~= b.key then
      return a.key < b.key
    end
    return a.phase < b.phase
  end)
  return out
end

return PosePerformanceCounter
