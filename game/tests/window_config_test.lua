-- Shared window configuration contract. love.conf (executed by the LÖVE
-- binary before any game module exists) and the field runtime both resolve
-- the reference window size from game/src/WindowConfig.lua, and environment
-- dimensions are parsed by the same pure helper so the strictness lives in a
-- testable function instead of inside the untestable conf.lua. The consumer
-- scan pins that both files use the named reference: a raw 640/480 literal
-- in either would recreate the drift the audit flagged.

local Assert = require("tests.support.Assert")
local WindowConfig = require("game.src.WindowConfig")

local T = {}

local function readFile(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

function T.reference_resolution_is_named_once()
  Assert.equal(WindowConfig.REFERENCE_WIDTH, 640)
  Assert.equal(WindowConfig.REFERENCE_HEIGHT, 480)
end

function T.positive_integer_dimensions_parse()
  local width, err = WindowConfig.parseEnvDimension("800", "G4RECOMP_WINDOW_WIDTH")
  Assert.isNil(err)
  Assert.equal(width, 800)
end

function T.unset_dimensions_are_absent()
  local width, err = WindowConfig.parseEnvDimension(nil, "G4RECOMP_WINDOW_WIDTH")
  Assert.isNil(width)
  Assert.isNil(err)
end

local function assertRejected(raw, envName)
  local value, err = WindowConfig.parseEnvDimension(raw, envName)
  Assert.isNil(value)
  Assert.notNil(err)
  ---@cast err string
  Assert.notNil(err:find(envName, 1, true), "the error must name the offending variable")
end

function T.zero_dimensions_are_rejected()
  assertRejected("0", "G4RECOMP_WINDOW_WIDTH")
end

function T.negative_dimensions_are_rejected()
  assertRejected("-5", "G4RECOMP_WINDOW_HEIGHT")
end

function T.fractional_dimensions_are_rejected()
  assertRejected("12.5", "G4RECOMP_WINDOW_WIDTH")
end

function T.garbage_dimensions_are_rejected()
  assertRejected("garbage", "G4RECOMP_WINDOW_HEIGHT")
end

-- The named reference must be the single source used by both consumers.
function T.conf_and_runtime_use_the_named_reference()
  for _, path in ipairs({ "game/conf.lua", "game/src/game/FieldRuntime.lua" }) do
    local contents = readFile(path)
    Assert.notNil(contents:find("REFERENCE_WIDTH", 1, true), path .. " must use the named reference width")
    Assert.notNil(contents:find("REFERENCE_HEIGHT", 1, true), path .. " must use the named reference height")
    Assert.isNil(contents:find("640", 1, true), path .. " must not carry a raw 640 literal")
    Assert.isNil(contents:find("480", 1, true), path .. " must not carry a raw 480 literal")
  end
end

return { tests = T }
