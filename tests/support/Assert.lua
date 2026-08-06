-- Minimal assertion helpers. Every assertion raises a plain string on failure,
-- which the runner reports. Keep this dependency-free so pure modules can be
-- tested under bare LuaJIT as well as LÖVE.

local Assert = {}

local function fail(msg)
  error(msg, 2)
end

local function repr(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function Assert.isTrue(v, msg)
  if not v then fail(msg or ("expected truthy, got " .. repr(v))) end
end

function Assert.isFalse(v, msg)
  if v then fail(msg or ("expected falsy, got " .. repr(v))) end
end

function Assert.isNil(v, msg)
  if v ~= nil then fail(msg or ("expected nil, got " .. repr(v))) end
end

function Assert.notNil(v, msg)
  if v == nil then fail(msg or "expected non-nil, got nil") end
end

function Assert.equal(actual, expected, msg)
  if actual ~= expected then
    fail(msg or ("expected " .. repr(expected) .. ", got " .. repr(actual)))
  end
end

-- Equality within a tolerance, for values that pass through fixed-point or
-- matrix arithmetic.
function Assert.near(actual, expected, tolerance, msg)
  tolerance = tolerance or 1e-9
  if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
    fail(msg or ("expected " .. repr(expected) .. " +/- " .. repr(tolerance)
      .. ", got " .. repr(actual)))
  end
end

-- Deep structural equality for tables of scalars/tables.
function Assert.deepEqual(actual, expected, path)
  path = path or "value"
  if type(actual) ~= type(expected) then
    fail(path .. ": type mismatch " .. type(actual) .. " ~= " .. type(expected))
  end
  if type(expected) ~= "table" then
    if actual ~= expected then
      fail(path .. ": " .. repr(actual) .. " ~= " .. repr(expected))
    end
    return
  end
  for k, v in pairs(expected) do
    Assert.deepEqual(actual[k], v, path .. "." .. tostring(k))
  end
  for k in pairs(actual) do
    if expected[k] == nil then
      fail(path .. "." .. tostring(k) .. ": unexpected key")
    end
  end
end

-- Runs fn(); asserts it raised. Returns the raised value (string or table).
function Assert.throws(fn, msg)
  local ok, err = pcall(fn)
  if ok then fail(msg or "expected error, but call succeeded") end
  return err
end

return Assert
