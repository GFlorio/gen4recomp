-- Production-composed contract for the high-level sign script API through
-- the built-in semantic styles: the handwritten demo override script
-- (demo.signpost) runs S.sign and S.trainerTip through the real production
-- composition with no boot-config style descriptors. S.sign must resolve
-- its semantic appearance to the built-in hgss.signpost style, present the
-- signpost window immediately with no source-only type/map data, print its
-- message instantly, and dismiss on the A edge; S.trainerTip then presents
-- with the semantic trainer_tip style, types at the player text speed, and
-- dismisses the same way. The whole journey runs in one production boot
-- with zero script faults and zero render attempts. Imported ROM scripts
-- keep the low-level nodes (covered by the signpost-opcode scenarios), and
-- the no-stale-sourceAppearance contract after an imported sign lives in
-- that journey.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")
local AcceptanceScripts = require("tests.acceptance.support.AcceptanceScripts")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "script", "signpost", "hgss", "mod" },
  },
  tests = {},
}

local DEMO_SIGNPOST = "demo.signpost"

local function withGame(fn)
  local game = AcceptanceHarness.new():boot({
    versionId = "heartgold",
    map = "MAP_NEW_BARK",
    save = "fresh",
    fieldOptions = { acceptanceScripts = AcceptanceScripts },
  })
  local ok, err = xpcall(function()
    fn(game)
    Assert.equal(game:renderAttempts(), 0)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

local function scriptFaults(game)
  local faults = {}
  for _, record in ipairs(game.hosts.events.records) do
    if record.name == "script.error" then
      faults[#faults + 1] = {
        scriptId = record.payload.scriptId,
        code = record.payload.code,
        command = record.payload.context and record.payload.context.command,
      }
    end
  end
  return faults
end

local function faultCode(faults)
  return faults[1] and faults[1].code or "none"
end

local function signpostStatus(game)
  return game.runtime.signpost:status()
end

-- The whole high-level journey in one production boot: S.sign resolves its
-- semantic appearance to the built-in hgss.signpost style, opens and
-- dismisses on A; S.trainerTip opens with the semantic trainer_tip style,
-- types at the player cadence, and dismisses; the script ends with zero
-- script faults. Neither presentation carries source type/map data.
function T.tests.high_level_sign_script_presents_and_dismisses_without_source_appearance()
  withGame(function(game)
    game:startScript(DEMO_SIGNPOST)

    -- The executable program owns the complete blocking lifecycle: the sign
    -- nodes carry the canonical one-table spec (message + semantic
    -- appearance).
    local composed = assert(game.runtime.scripts.composition:effective(DEMO_SIGNPOST))
    local graph = assert(composed.entries[1].graph, "the demo script must compile to an executable graph")
    local signCount = 0
    for _, node in pairs(graph.nodes) do
      if node.op == "sign" then
        signCount = signCount + 1
        Assert.notNil(node.message, "high-level sign nodes carry the canonical message spec")
        Assert.equal(node.appearance, "sign", "high-level sign nodes carry the canonical semantic appearance")
      end
    end
    Assert.isTrue(signCount > 0, "the demo script must compile sign nodes")

    -- S.sign presents the window immediately with the built-in style id
    -- resolved from the semantic appearance and no source type/map data;
    -- the message prints instantly.
    local status = signpostStatus(game)
    Assert.equal(#scriptFaults(game), 0, "S.sign must not fault at open, got: " .. faultCode(scriptFaults(game)))
    Assert.isTrue(status.active, "S.sign must present the signpost window immediately")
    Assert.equal(status.styleId, "hgss.signpost", "S.sign must resolve its semantic appearance to the built-in style")
    Assert.isNil(status.sourceAppearance, "S.sign must not carry source-only type/map data")
    Assert.isTrue(status.printDone, "S.sign must print its message instantly")

    -- A dismisses the signpost; the script then opens the Trainer Tip.
    game:pressAction()
    Assert.isFalse(signpostStatus(game).active, "A must dismiss the S.sign window")
    Assert.equal(signpostStatus(game).command, "nop")

    -- S.trainerTip presents with the semantic trainer_tip style, types at
    -- the player text speed (never instantly), and keeps no source
    -- appearance.
    game:advanceUntil("S.trainerTip opens its typed print", function()
      local tip = signpostStatus(game)
      return tip.active and not tip.printDone
    end, 8)
    local tip = signpostStatus(game)
    Assert.equal(#scriptFaults(game), 0, "S.trainerTip must not fault at open, got: " .. faultCode(scriptFaults(game)))
    Assert.equal(tip.styleId, "hgss.trainer_tip", "S.trainerTip must resolve its semantic appearance")
    Assert.isNil(tip.sourceAppearance, "S.trainerTip must not carry source-only type/map data")

    game:advanceUntil("the trainer tip print completes", function()
      return signpostStatus(game).printDone
    end, 64)
    Assert.equal(#scriptFaults(game), 0, "the trainer tip print must not fault, got: " .. faultCode(scriptFaults(game)))

    -- A dismisses the Trainer Tip and the script ends; the signpost stays
    -- closed and zero faults were recorded through the whole journey.
    game:pressAction()
    Assert.isFalse(signpostStatus(game).active, "A must dismiss the trainer tip window")
    Assert.equal(signpostStatus(game).command, "nop")
    game:advanceUntil("the demo script ends after dismissal", function()
      for _, record in ipairs(game.hosts.events.records) do
        if record.name == "script.ended" then
          return true
        end
      end
      return false
    end, 8)
    Assert.equal(
      #scriptFaults(game),
      0,
      "the demo sign script must complete without faulting, got: " .. faultCode(scriptFaults(game))
    )
    Assert.isFalse(signpostStatus(game).active, "the signpost must stay closed after the script ends")
  end)
end

return T
