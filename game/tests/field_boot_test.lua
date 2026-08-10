-- Field boot selection remains independent of the presentation app.

local Assert = require("tests.support.Assert")
local FieldBoot = require("game.src.game.FieldBoot")

local T = {}

function T.one_ready_version_selects_its_runtime()
  Assert.equal(FieldBoot.select({ "heartgold" }), "heartgold")
end

function T.ready_version_ids_are_validated_before_selection()
  Assert.throws(function()
    FieldBoot.select({ "" })
  end)
end

function T.multiple_ready_versions_expose_a_deterministic_selection()
  local selection = FieldBoot.select({ "heartgold", "soulsilver" })
  Assert.deepEqual(selection:versions(), { "heartgold", "soulsilver" })
  Assert.equal(selection:choose("soulsilver"), "soulsilver")
end

return T
