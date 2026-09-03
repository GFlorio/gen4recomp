-- The physical-cell classification authority: an ordinary header resolves to
-- its own logical map, the shared EVERYWHERE header inherits the current
-- logical map, and an unsupported header is never silent filler. Malformed
-- identity input fails loudly instead of resolving to a plausible map.

local Assert = require("tests.support.Assert")
local FieldZoneIdentity = require("libs.hgss.src.field.FieldZoneIdentity")

local T = {}

local function headerCoverage(headerId)
  return {
    mapHeaderAt = function(_, _, _)
      return headerId
    end,
  }
end

function T.ordinary_header_resolves_to_its_own_logical_map()
  Assert.isFalse(FieldZoneIdentity.isPhysicalOnlyCell(60))
  Assert.equal(FieldZoneIdentity.logicalZoneAt(headerCoverage(60), 1, 2, 60), 60)
  Assert.equal(FieldZoneIdentity.logicalZoneAt(headerCoverage(60), 1, 2, 61), 60)
end

function T.everywhere_header_inherits_the_current_logical_map()
  Assert.isTrue(FieldZoneIdentity.isPhysicalOnlyCell(FieldZoneIdentity.EVERYWHERE_MAP_HEADER))
  Assert.equal(FieldZoneIdentity.EVERYWHERE_MAP_HEADER, 0)
  Assert.equal(FieldZoneIdentity.logicalZoneAt(headerCoverage(0), 1, 2, 60), 60)
  Assert.equal(FieldZoneIdentity.logicalZoneAt(headerCoverage(0), 1, 2, 67), 67)
end

function T.unsupported_header_is_not_silent_filler()
  Assert.isFalse(FieldZoneIdentity.isPhysicalOnlyCell(999))
  Assert.equal(FieldZoneIdentity.logicalZoneAt(headerCoverage(999), 1, 2, 60), 999)
end

function T.missing_physical_header_preserves_out_of_coverage()
  Assert.isNil(FieldZoneIdentity.logicalZoneAt(headerCoverage(nil), 1, 2, 60))
end

function T.malformed_identity_fails_loudly()
  local err = Assert.throws(function()
    FieldZoneIdentity.logicalZoneAt({}, 1, 2, 60)
  end)
  Assert.isTrue(tostring(err):find("mapHeaderAt", 1, true) ~= nil)
  err = Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- a missing current map id is malformed caller input
    FieldZoneIdentity.logicalZoneAt(headerCoverage(60), 1, 2, nil)
  end)
  Assert.isTrue(tostring(err):find("current logical map id", 1, true) ~= nil)
  err = Assert.throws(function()
    ---@diagnostic disable-next-line: param-type-mismatch -- a missing header id is malformed caller input
    FieldZoneIdentity.isPhysicalOnlyCell(nil)
  end)
  Assert.isTrue(tostring(err):find("map header id", 1, true) ~= nil)
end

return { metadata = { capabilities = {} }, tests = T }
