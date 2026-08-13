-- The graphics layer, as seen by discovery. A renderer test that quietly
-- returns when `love.graphics` is nil reports a pass for work it never did, so
-- the corpus must contain no availability guard at all: real GPU work belongs to
-- suites under the graphics discovery root that require the graphics capability,
-- and a host without one skips explicitly through the runner.

local Assert = require("tests.support.Assert")
local Runner = require("tests.run")

local T = {}

local listing = nil

local function corpus()
  if listing == nil then
    listing = Runner.list({})
  end
  return listing
end

local function sourceOf(moduleName)
  local path = moduleName:gsub("%.", "/") .. ".lua"
  local file = assert(io.open(path, "r"), "cannot read test source: " .. path)
  local source = file:read("*a")
  file:close()
  return path, source
end

local function declaresCapability(suite, name)
  for _, capability in ipairs(suite.capabilities or {}) do
    if capability == name then
      return true
    end
  end
  return false
end

-- Availability probes that let a test body vanish without a skip result. The
-- needles are assembled so this module never matches itself.
local FORBIDDEN_GUARDS = {
  "has" .. "Graphics",
  "love and love." .. "graphics",
  "love and love." .. "image",
  "if not love." .. "graphics",
}

function T.the_corpus_owns_at_least_one_graphics_suite()
  local graphics = {}
  for _, suite in ipairs(corpus()) do
    if suite.layer == "graphics" then
      graphics[#graphics + 1] = suite
    end
  end

  Assert.isTrue(#graphics > 0, "no suite lives under the graphics root, so --layer graphics runs nothing")
end

function T.graphics_layer_selection_uses_the_graphics_root()
  local graphics = Runner.list({ layer = "graphics" })

  Assert.isTrue(#graphics > 0, "--layer graphics must select the suites under the graphics root")
  for _, suite in ipairs(graphics) do
    Assert.equal(suite.layer, "graphics")
  end
end

function T.every_graphics_suite_requires_the_graphics_capability()
  for _, suite in ipairs(corpus()) do
    if suite.layer == "graphics" then
      Assert.isTrue(
        declaresCapability(suite, "graphics"),
        "graphics suite does not require the graphics capability: " .. suite.module
      )
    end
  end
end

function T.no_suite_gates_a_test_body_on_module_availability()
  local offenders = {}
  for _, suite in ipairs(corpus()) do
    local path, source = sourceOf(suite.module)
    for _, needle in ipairs(FORBIDDEN_GUARDS) do
      if source:find(needle, 1, true) then
        offenders[#offenders + 1] = path .. ": " .. needle
      end
    end
  end

  Assert.isTrue(
    #offenders == 0,
    "availability guards make a skipped test look like a pass; use the graphics capability or context:skip:\n  "
      .. table.concat(offenders, "\n  ")
  )
end

function T.suites_that_create_gpu_resources_belong_to_the_graphics_layer()
  local offenders = {}
  for _, suite in ipairs(corpus()) do
    local path, source = sourceOf(suite.module)
    if source:find("love%.graphics%.new") and suite.layer ~= "graphics" then
      offenders[#offenders + 1] = path .. " (layer " .. suite.layer .. ")"
    end
  end

  Assert.isTrue(
    #offenders == 0,
    "these suites create real GPU resources but are not counted as graphics tests:\n  "
      .. table.concat(offenders, "\n  ")
  )
end

-- The three smoke behaviors this layer exists to actually execute.
function T.the_graphics_layer_covers_shaders_render_targets_and_the_dialogue_atlas()
  local names = {}
  for _, suite in ipairs(corpus()) do
    if suite.layer == "graphics" then
      for _, test in ipairs(suite.tests) do
        names[#names + 1] = test:lower()
      end
    end
  end

  local function covers(needle)
    for _, name in ipairs(names) do
      if name:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  Assert.isTrue(covers("shader"), "no graphics test compiles a shader")
  Assert.isTrue(covers("render_target") or covers("canvas"), "no graphics test allocates a canvas or render target")
  Assert.isTrue(covers("atlas"), "no graphics test loads the dialogue atlas")
  Assert.isTrue(covers("nine_slice"), "no graphics test draws the dialogue nine-slice")
end

return { tests = T }
