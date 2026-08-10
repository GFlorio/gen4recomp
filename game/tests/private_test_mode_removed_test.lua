-- The private test mode is retired. `scripts/test.sh` is the single test
-- entrypoint, so the second plumbing -- the ROM-conformance flag parsed by the app
-- entry point and its LÖVE configuration, and the shell wrapper that passed it
-- -- must be gone rather than kept as a compatibility alias.
--
-- The app entry point is checked by reading its source because `game/main.lua`
-- installs LÖVE callbacks and cannot be required from a test. Needles are
-- assembled at runtime so this module does not match itself.

local Assert = require("tests.support.Assert")

local T = {}

local FLAG = "--test" .. "-private"
local SCRIPT = "test-" .. "private.sh"
local FIELD = "test" .. "Private"

local function readFile(path)
  local handle = io.open(path, "r")
  if handle == nil then
    return nil
  end
  local contents = handle:read("*a")
  handle:close()
  return contents
end

local function assertContains(path, needle)
  local source = assert(readFile(path), "can read " .. path)
  Assert.isTrue(source:find(needle, 1, true) ~= nil, path .. " must document or invoke " .. needle)
end

-- The app entry point and its LÖVE configuration no longer know about a
-- private test mode, and the wrapper script is gone.
function T.the_app_no_longer_has_a_private_test_mode()
  for _, path in ipairs({ "game/main.lua", "game/conf.lua" }) do
    local source = assert(readFile(path), "can read " .. path)
    Assert.isTrue(source:find(FLAG, 1, true) == nil, path .. " must not parse or document " .. FLAG)
    Assert.isTrue(source:find(FIELD, 1, true) == nil, path .. " must not carry a " .. FIELD .. " option")
  end
  Assert.isNil(readFile("scripts/" .. SCRIPT), "scripts/" .. SCRIPT .. " must be deleted, not kept as an alias")
end

-- The durable command/documentation contract is intentionally narrow: it checks
-- the files users and CI actually follow, without a fragile checkout-wide scan.
function T.workflow_and_documentation_use_the_single_test_command()
  assertContains(".github/workflows/ci.yml", "scripts/test.sh")
  assertContains("README.md", "docs/testing.md")
  assertContains("README.md", "scripts/test.sh")
  assertContains("docs/testing.md", "G4RECOMP_REQUIRE_ROM_TESTS=1")
  assertContains("docs/testing.md", "--layer acceptance")
  assertContains("docs/architecture.md", "Runtime/presentation boundary")
  assertContains("docs/architecture.md", "acceptance layer")

  for _, path in ipairs({ "AGENTS.md", "CLAUDE.md" }) do
    assertContains(path, "discovered recursively")
    assertContains(path, "explicit skip")
    assertContains(path, "layer metadata")
  end
end

return T
