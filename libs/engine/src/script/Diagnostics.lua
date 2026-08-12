-- Diagnostics and deterministic tracing for the script platform.
-- The trace recorder is a pure-domain sink: the
-- scheduler and tasks emit immutable records (context grants, node
-- executions, task polls and completions, readyAtTick changes), and the
-- recorder preserves insertion order so tests and golden traces can assert
-- exact per-tick sequences. Records serialize through LuaWriter so identical
-- runs produce identical text. Pure domain module: no love dependency.

local LuaWriter = require("libs.codec.src.LuaWriter")

local Diagnostics = {}

---@class Diagnostics.TraceRecorder
---@field private _records table[]
local TraceRecorder = {}
TraceRecorder.__index = TraceRecorder

---@return Diagnostics.TraceRecorder
function Diagnostics.newTraceRecorder()
  return setmetatable({ _records = {} }, TraceRecorder)
end

-- The sink the scheduler accepts: records one immutable trace record.
---@param record table
function TraceRecorder:record(record)
  assert(type(record) == "table", "trace record must be a table")
  self._records[#self._records + 1] = record
end

-- All records in insertion order (do not mutate).
---@return table[]
function TraceRecorder:records()
  return self._records
end

-- Deterministic one-line rendering of every record, for golden traces and
-- console diagnostics.
---@return string[]
function TraceRecorder:lines()
  local out = {}
  for _, record in ipairs(self._records) do
    out[#out + 1] = LuaWriter.encode(record)
  end
  return out
end

return Diagnostics
