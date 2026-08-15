-- Production-composed window-style catalog contracts: the boot-time mod
-- extension seam accepts one validated complete custom descriptor (id, role,
-- contentGeometry -- a full record, no inheritance), and rejects a derived
-- descriptor that names a base, a descriptor under the reserved hgss.
-- prefix, and a duplicate custom id -- each rejection is a loud boot failure
-- naming the offending descriptor. The user-visible journey that consumes
-- the seam (S.sign with the custom style) lives with the other high-level
-- sign scenarios.

local Assert = require("tests.support.Assert")
local AcceptanceHarness = require("tests.acceptance.support.AcceptanceHarness")

local T = {
  metadata = {
    capabilities = { "rom_dump", "derived_cache" },
    tags = { "field", "presentation", "signpost", "catalog", "mod" },
  },
  tests = {},
}

-- A complete custom descriptor: the only shape the immutable catalog accepts
-- (full record, no base/inheritance).
local COMPLETE_STYLE = {
  id = "mod.route_sign",
  role = "signpost",
  contentGeometry = { x = 16, y = 152, width = 216, height = 32 },
}

-- Boot the production runtime with the given window style descriptors and
-- require the boot to fail naming the offending descriptor id. A successful
-- boot is a contract failure; a boot that fails without naming the
-- descriptor is an unrelated failure and also a test failure.
local function bootFailureNames(descriptors, id)
  local game
  local ok, err = pcall(function()
    game = AcceptanceHarness.new():boot({
      versionId = "heartgold",
      map = "MAP_NEW_BARK",
      save = "fresh",
      fieldOptions = { windowStyleDescriptors = descriptors },
    })
  end)
  if game then
    game:close()
  end
  Assert.isFalse(ok, "the runtime must reject the window style descriptors at boot")
  Assert.isTrue(
    tostring(err):find(id, 1, true) ~= nil,
    "the boot failure must name the offending descriptor " .. id .. ", got: " .. tostring(err)
  )
end

-- Custom descriptors are complete records, not inheritance deltas: a
-- descriptor that names a base must be rejected at boot instead of resolving
-- against the built-ins.
function T.tests.derived_descriptor_with_a_base_is_rejected_at_boot()
  bootFailureNames({
    { id = "mod.route_sign", base = "hgss.signpost" },
  }, "mod.route_sign")
end

-- The hgss. prefix is reserved for the built-in styles: a mod descriptor
-- under it must be rejected at boot, never silently shadowing a built-in.
function T.tests.reserved_hgss_descriptor_id_is_rejected_at_boot()
  bootFailureNames({
    { id = "hgss.mod_style", role = "signpost", contentGeometry = COMPLETE_STYLE.contentGeometry },
  }, "hgss.mod_style")
end

-- Two boot-config descriptors claiming one id are ambiguous composition
-- input: the duplicate must be rejected at boot.
function T.tests.duplicate_custom_descriptor_id_is_rejected_at_boot()
  bootFailureNames({
    COMPLETE_STYLE,
    COMPLETE_STYLE,
  }, "mod.route_sign")
end

return T
