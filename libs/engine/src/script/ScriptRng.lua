-- Deterministic script RNG : the only random source the
-- scripting contract exposes. It is a pure-Lua Lehmer LCG (no bit library,
-- no love, never math.random), seeded from save/session state rather than
-- wall-clock time, and its state is serialized with the save so identical
-- fixed-tick input and save data produce identical rolls. Tests and coverage
-- inject a deterministic seed. Pure domain module: no love dependency.

local ScriptRng = {}
ScriptRng.__index = ScriptRng

ScriptRng.SCHEMA_NAME = "g4-script-rng-v1"

local MODULUS = 0x7FFFFFFF
local MULTIPLIER = 48271

---@class ScriptRngState
---@field _state integer
---@field _calls integer

-- Derive a nonzero seed deterministically from a string (e.g. a save or
-- session identity).
---@param seedText string|nil
---@return integer
function ScriptRng.deriveSeed(seedText)
  local seed = 0x2545F491
  if seedText ~= nil then
    for i = 1, #seedText do
      local byte = seedText:byte(i)
      seed = (seed * 33 + byte) % MODULUS
    end
  end
  if seed == 0 then
    seed = 1
  end
  return seed
end

-- Advance the LCG; the state is the serializable source of truth.
function ScriptRng:nextRaw()
  self._state = (self._state * MULTIPLIER) % MODULUS
  self._calls = self._calls + 1
  return self._state
end

-- Uniform integer in [0, maxExclusive).
---@param maxExclusive integer
---@return integer
function ScriptRng:nextInt(maxExclusive)
  assert(type(maxExclusive) == "number" and maxExclusive > 0, "maxExclusive must be a positive integer")
  return self:nextRaw() % maxExclusive
end

-- Uniform integer in [minInclusive, maxInclusive].
---@param minInclusive integer
---@param maxInclusive integer
---@return integer
function ScriptRng:range(minInclusive, maxInclusive)
  local span = maxInclusive - minInclusive + 1
  return minInclusive + self:nextRaw() % span
end

-- True with probability numerator / denominator.
---@param numerator integer
---@param denominator integer
---@return boolean
function ScriptRng:chance(numerator, denominator)
  return self:nextRaw() % denominator < numerator
end

-- Serialized state for the save schema.
---@return table
function ScriptRng:serialize()
  return { state = self._state, calls = self._calls }
end

-- Create an RNG instance. `seed` may be a number or a string (derived).
---@param seed integer|string|nil
---@return table rng
function ScriptRng.new(seed)
  local state
  if type(seed) == "string" then
    state = ScriptRng.deriveSeed(seed)
  elseif type(seed) == "number" then
    state = seed
  else
    state = ScriptRng.deriveSeed(nil)
  end
  if state == 0 then
    state = 1
  end
  return setmetatable({
    _state = state,
    _calls = 0,
  }, ScriptRng)
end

-- Rebuild an RNG from serialized state.
---@param record table
---@return table rng
function ScriptRng.restore(record)
  local rng = ScriptRng.new(record.state or ScriptRng.deriveSeed(nil))
  rng._calls = record.calls or 0
  return rng
end

return ScriptRng
