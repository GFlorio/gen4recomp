-- FieldRuntime signpost-host composition contract: the production runtime
-- constructs the FieldSignpostController with the dialogue layout and the
-- player's text-speed cadence, the script platform builds ScriptSignpostHost
-- around it with the dialogue host's public message resolution, injects it
-- into scheduler services, and the advanceAsync closure advances the
-- controller once per scheduler tick. An active signpost blocks field-save
-- capture; closing it restores a capturable boundary. One production boot
-- amortizes the whole lifecycle: composition, wipe motion, save gate, and
-- the typed-print cadence share the same fresh session state.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "scripts", "signpost" },
  },
  tests = {},
}

-- The controller and host exist, the host sits in the scheduler services
-- under the key signpost tasks will read, and the advanceAsync closure steps
-- the controller exactly once per production tick: a queued wipe moves one
-- 16px step per tick. The same boot then proves the save gate follows the
-- controller's presented window and that a typed print uses the fresh-player
-- fastest cadence captured from the player options at construction, never a
-- host-chosen constant.
function T.tests.runtime_composes_the_signpost_host_and_owns_its_lifecycle()
  local game = AcceptanceHarness.new({ versions = { "heartgold" } }):boot({
    versionId = "heartgold",
    map = "MAP_BURNED_TOWER_1F",
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local runtime = game.runtime
    local signpost = runtime.signpost
    local host = runtime.scripts.signpostHost
    Assert.isTrue(type(signpost) == "table", "the runtime must own the signpost controller")
    Assert.isTrue(type(host) == "table", "the script platform must expose the signpost host")
    local scheduler = runtime.scripts.scheduler --[[@as any]]
    Assert.equal(scheduler._services.signpost, host, "the host is injected into scheduler services")

    signpost:setCommand("wipe_in")
    game:step()
    Assert.equal(signpost:status().logicalYOffset, -32, "one 16px wipe step per scheduler tick")
    game:step()
    Assert.equal(signpost:status().logicalYOffset, -16)
    game:step()
    Assert.equal(signpost:status().logicalYOffset, 0)
    Assert.equal(
      signpost:status().command,
      "wipe_in",
      "the command is held on the motion update that reaches the endpoint"
    )
    game:step()
    Assert.equal(signpost:status().command, "nop", "the following tick completes the wipe")

    -- An active signpost is transient session state: the save gate stays
    -- closed while the window is presented and reopens when the signpost
    -- hides.
    signpost:setCommand("show")
    game:step()
    Assert.isTrue(signpost:status().active)
    Assert.isNil(runtime:captureGameSave(), "an active signpost defers the save")
    signpost:setCommand("hide")
    game:step()
    Assert.isFalse(signpost:status().active)
    Assert.notNil(runtime:captureGameSave(), "closing the signpost restores a capturable boundary")

    -- The typed print path travels the real production chain: the host
    -- resolves the message through the dialogue host's public operation
    -- against the generated message bank, and the controller reveals one
    -- glyph per two scheduler ticks.
    host:printTyped("msg.hgss.0542.00009", {}, {})
    Assert.isFalse(host:status().printDone, "the typed print starts incomplete")
    local ticks = 0
    while not host:status().printDone and ticks < 64 do
      game:step()
      ticks = ticks + 1
    end
    Assert.isTrue(ticks > 0 and ticks <= 16, "fastest cadence must complete within 16 host ticks")
    Assert.isTrue(host:status().printDone, "the print completes at the cadence")
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
