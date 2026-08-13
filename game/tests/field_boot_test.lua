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

-- Several ready versions return the ready array itself: the caller offers a
-- choice over exactly the versions it found, with no intermediate selection
-- object.
function T.multiple_ready_versions_return_the_ready_array()
  local versions = { "heartgold", "soulsilver" }
  local decision = FieldBoot.select(versions)
  Assert.equal(decision, versions, "the ready array itself, not a copy or wrapper")
  Assert.deepEqual(decision, { "heartgold", "soulsilver" })
end

return T
