-- RuntimeAllocationProfiler: the cheap per-tick allocation counters of the
-- animation path (spec section 39). Instrumented call sites count the
-- objects they create per tick (a pose state per evaluatePose, a draw item
-- per mesh, an attachment advance per updateFixed) -- integers only, no GC
-- involvement, no full profiler. beginTick/endTick fold one tick's counts
-- into the running totals while keeping the last tick readable, so the
-- per-frame allocation cost of a scene can be read after every draw. Pure
-- domain module.

local RuntimeAllocationProfiler = {}
RuntimeAllocationProfiler.__index = RuntimeAllocationProfiler

---@class RuntimeAllocationProfiler
---@field totals table<string, integer>
---@field current table<string, integer>|nil -- the open tick, nil outside one
---@field last table<string, integer> -- the last folded tick
---@field tickActive boolean

function RuntimeAllocationProfiler.new()
  return setmetatable({
    totals = {},
    current = nil,
    last = {},
    tickActive = false,
  }, RuntimeAllocationProfiler)
end

-- Open the per-tick accumulation window. Raises when a tick is already open.
function RuntimeAllocationProfiler:beginTick()
  assert(not self.tickActive, "nested allocation tick")
  self.tickActive = true
  self.current = {}
end

-- Count `count` allocations of `site`. Inside a tick the count folds into
-- the tick's lastTick view; outside one it lands in the totals immediately
-- (rare events like band swaps need no tick).
function RuntimeAllocationProfiler:add(site, count)
  assert(type(site) == "string" and #site > 0, "allocation site must be a non-empty string")
  count = count or 1
  assert(count >= 1 and math.floor(count) == count, "allocation count must be a positive integer")
  local bucket = self.tickActive and self.current or self.totals
  bucket[site] = (bucket[site] or 0) + count
end

-- Fold the open tick into the totals and expose it as the last tick.
function RuntimeAllocationProfiler:endTick()
  assert(self.tickActive, "endTick without beginTick")
  self.tickActive = false
  self.last = self.current
  self.current = nil
  for site, count in pairs(self.last) do
    self.totals[site] = (self.totals[site] or 0) + count
  end
end

-- The total count of `site` across every tick.
---@return integer
function RuntimeAllocationProfiler:count(site)
  return self.totals[site] or 0
end

-- The count of `site` in the last folded tick (0 outside a tick).
---@return integer
function RuntimeAllocationProfiler:lastTick(site)
  return self.last[site] or 0
end

-- Every site with totals, sorted: { site, total, last }.
---@return { site: string, total: integer, last: integer }[]
function RuntimeAllocationProfiler:report()
  local out = {}
  for site, total in pairs(self.totals) do
    out[#out + 1] = { site = site, total = total, last = self.last[site] or 0 }
  end
  table.sort(out, function(a, b)
    return a.site < b.site
  end)
  return out
end

return RuntimeAllocationProfiler
