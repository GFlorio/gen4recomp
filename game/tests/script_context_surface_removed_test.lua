-- Script-context conformance contraction (D18): the raw ctx surface must not
-- carry methods without production backing. `ctx.dialogue.resolve` called
-- `dialogue.resolveText` (production exposes `resolveMessage`), and
-- `ctx.movement` called `actors:isBusy`/`actors:canMove` (production
-- `ScriptActorWorld` exposes neither; `FakeServices` implemented both,
-- concealing the mismatch). Both groups are deleted; the concealing fake
-- methods go with them. This is a repo-content scan: it reads source files
-- and never executes the game.

local Assert = require("tests.support.Assert")

local T = {
  metadata = {
    layer = "component",
    tags = { "regression", "repo-content" },
  },
  tests = {},
}

local SCRIPT_CONTEXT_PATH = "libs/engine/src/script/ScriptContext.lua"
local FAKE_SERVICES_PATH = "tests/support/script/FakeServices.lua"

local function readFile(path)
  local handle = assert(io.open(path, "r"), "cannot read " .. path)
  local contents = handle:read("*a")
  handle:close()
  return contents
end

-- The deleted ctx surface: resolveText (ctx.dialogue.resolve's production
-- mismatch) and the two ctx.movement calls. isBusy/canMove may legitimately
-- exist on the importer stub in game/tests/app_state_test.lua, so the scan
-- is file-scoped to the ctx module and the concealing fake.
local SCRIPT_CONTEXT_NEEDLES = {
  "resolveText",
  "isBusy",
  "canMove",
}

local FAKE_SERVICES_NEEDLES = {
  "isBusy",
  "canMove",
}

function T.tests.script_context_carries_no_unbacked_methods()
  local contents = readFile(SCRIPT_CONTEXT_PATH)
  for _, needle in ipairs(SCRIPT_CONTEXT_NEEDLES) do
    Assert.isNil(
      contents:find(needle, 1, true),
      SCRIPT_CONTEXT_PATH .. " must not reference the unbacked surface (" .. needle .. ")"
    )
  end
end

function T.tests.fake_services_no_longer_conceal_the_mismatch()
  local contents = readFile(FAKE_SERVICES_PATH)
  for _, needle in ipairs(FAKE_SERVICES_NEEDLES) do
    Assert.isNil(
      contents:find(needle, 1, true),
      FAKE_SERVICES_PATH .. " must not fake the deleted ctx.movement surface (" .. needle .. ")"
    )
  end
end

return T
