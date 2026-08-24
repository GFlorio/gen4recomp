-- Tests source-derived identity checks for canonical vanilla coordinate scripts.

local Assert = require("tests.support.Assert")
local Identity = require("romdump.src.digest.script.VanillaBindingIdentity")

local T = { tests = {} }

local MAP = { id = 60, scriptsMemberId = 842 }

local function event(scriptId)
  return { scriptId = scriptId }
end

function T.tests.parses_only_the_canonical_vanilla_namespace()
  Assert.deepEqual(
    Identity.parseCanonicalTarget("vanilla.hgss.scr_seq.0842.script_002"),
    { memberId = 842, scriptIndex = 2 }
  )
  for _, target in ipairs({
    "vanilla.hgss.scr_seq.842.script_002",
    "vanilla.hgss.scr_seq.0842.script_02",
    "vanilla.hgss.scr_seq.0842.script_002.extra",
    "other.hgss.scr_seq.0842.script_002",
  }) do
    Assert.isNil(Identity.parseCanonicalTarget(target), "near-miss target must not be parsed")
  end
end

function T.tests.derives_the_expected_target_from_source_identity()
  Assert.equal(Identity.expectedCoordinateTarget(MAP, event(3)), "vanilla.hgss.scr_seq.0842.script_002")
end

function T.tests.aliases_bypass_the_canonical_identity_rule()
  Assert.isTrue(Identity.validateCoordinateTarget(60, 0, "new_bark.coordinate.arrival", MAP, event(0)))
end

function T.tests.rejects_a_wrong_script_member_with_context()
  local result, err = Identity.validateCoordinateTarget(60, 0, "vanilla.hgss.scr_seq.0843.script_002", MAP, event(3))
  Assert.isNil(result)
  Assert.equal(assert(err).code, "VANILLA_BINDING_IDENTITY_MISMATCH")
  Assert.deepEqual(assert(err).context, {
    mapId = 60,
    eventIndex = 0,
    scriptsMemberId = 842,
    scriptId = 3,
    expectedTarget = "vanilla.hgss.scr_seq.0842.script_002",
    actualTarget = "vanilla.hgss.scr_seq.0843.script_002",
  })
end

function T.tests.rejects_an_off_by_one_script_suffix()
  local result, err = Identity.validateCoordinateTarget(60, 0, "vanilla.hgss.scr_seq.0842.script_003", MAP, event(3))
  Assert.isNil(result)
  Assert.equal(assert(err).code, "VANILLA_BINDING_IDENTITY_MISMATCH")
  Assert.equal(assert(err).context.expectedTarget, "vanilla.hgss.scr_seq.0842.script_002")
  Assert.equal(assert(err).context.actualTarget, "vanilla.hgss.scr_seq.0842.script_003")
end

function T.tests.rejects_a_zero_based_source_selector()
  local expected, err = Identity.expectedCoordinateTarget(MAP, event(0))
  Assert.isNil(expected)
  Assert.equal(assert(err).code, "VANILLA_BINDING_IDENTITY_INVALID")
  Assert.equal(assert(err).context.scriptId, 0)

  local result, validationErr =
    Identity.validateCoordinateTarget(60, 0, "vanilla.hgss.scr_seq.0842.script_000", MAP, event(0))
  Assert.isNil(result)
  Assert.equal(assert(validationErr).code, "VANILLA_BINDING_IDENTITY_INVALID")
end

return T
