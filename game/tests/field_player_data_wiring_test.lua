-- FieldRuntime player-data composition contract: a fresh boot copies and
-- validates the checked-in initial player-data manifest into its own
-- instance and wires the profile into the script platform, and the
-- production save -> resume round trip restores the saved player-data
-- bucket (never re-reads the initial manifest). The cadence mapping and the
-- model's strict validation live at the unit layer; this suite proves the
-- runtime composition in one production flow.

local Assert = require("tests.support.Assert")
local FieldPlayerManifest = require("data.manifests.field_player")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "persistence", "profile" },
  },
  tests = {},
}

local LAB = "MAP_NEW_BARK_ELMS_LAB_1F"

-- One fresh boot owns both contracts: the fresh session copies and validates
-- the initial manifest (mutating the runtime copy cannot corrupt the checked-
-- in manifest, and the script platform resolves the same profile through the
-- real wiring), then the production fresh -> save -> resume round trip proves
-- the saved bucket wins over the initial manifest and drives the platform.
function T.tests.fresh_copy_and_resume_round_trip_own_the_player_data()
  local game = AcceptanceHarness.new({ versions = { "heartgold" } }):boot({
    versionId = "heartgold",
    map = LAB,
    save = "fresh",
  })
  local ok, err = xpcall(function()
    local playerData = game.runtime.playerData
    Assert.equal(playerData.profile.name, FieldPlayerManifest.profile.name)
    Assert.equal(playerData.profile.gender, FieldPlayerManifest.profile.gender)
    Assert.equal(playerData.profile.trainerId, FieldPlayerManifest.profile.trainerId)
    Assert.equal(playerData.options.textFrame, FieldPlayerManifest.options.textFrame)
    Assert.equal(playerData.options.textSpeed, FieldPlayerManifest.options.textSpeed)
    Assert.isTrue(playerData ~= FieldPlayerManifest, "the fresh session must own a copy, not the manifest table")
    Assert.equal(game.runtime.scripts.player:name(), FieldPlayerManifest.profile.name)
    Assert.equal(game.runtime.scripts.player:gender(), FieldPlayerManifest.profile.gender)

    -- The fresh copy is the session's own: mutating it must not corrupt the
    -- checked-in manifest, and the save written at restart must carry it.
    game.runtime.playerData.profile.name = "HIKARI"
    game.runtime.playerData.profile.gender = 1
    Assert.equal(FieldPlayerManifest.profile.name, "GOLD", "mutating the runtime copy must not corrupt the manifest")

    local resumed = game:restart({ save = "resume" })
    Assert.equal(resumed.saveStatus, "Resumed saved field session")
    Assert.equal(
      resumed.runtime.playerData.profile.name,
      "HIKARI",
      "the saved bucket must win over the initial manifest"
    )
    Assert.equal(resumed.runtime.playerData.profile.gender, 1)
    Assert.equal(resumed.runtime.playerData.profile.trainerId, 0)
    Assert.equal(resumed.runtime.playerData.options.textSpeed, "mid")
    Assert.equal(resumed.runtime.scripts.player:name(), "HIKARI")
    Assert.equal(resumed.runtime.scripts.player:gender(), 1)
  end, debug.traceback)
  game:close()
  if not ok then
    error(err, 0)
  end
end

return T
