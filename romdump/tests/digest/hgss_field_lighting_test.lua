-- Tests for HgssFieldLighting: the HGSS light-type -> field-light profile
-- mapping that drives time-of-day lighting. Parsing of the profile text
-- itself is HgssFieldLightProfile's contract (romdump); runtime time
-- selection is FieldLightProfile's (libs/assets).

local Assert = require("tests.support.Assert")
local HgssFieldLighting = require("romdump.src.digest.HgssFieldLighting")

local T = {}

function T.maps_light_type_to_profile_and_path()
  Assert.equal(HgssFieldLighting.profileIdForLightType(0), 1)
  Assert.equal(HgssFieldLighting.profileIdForLightType(1), 0)
  Assert.equal(HgssFieldLighting.profileIdForLightType(2), 3)
  Assert.equal(HgssFieldLighting.profileIdForLightType(2, true), 4) -- second-dungeon override
  Assert.equal(HgssFieldLighting.profileIdForLightType(9), 0) -- unknown -> profile 0
  Assert.equal(HgssFieldLighting.pathForProfile(1), "data/area01light.txt")
  Assert.equal(HgssFieldLighting.resolve(0).sourcePath, "data/area01light.txt")
  Assert.equal(HgssFieldLighting.resolve(1).sourcePath, "data/area00light.txt")
end

return { metadata = { layer = "unit" }, tests = T }
