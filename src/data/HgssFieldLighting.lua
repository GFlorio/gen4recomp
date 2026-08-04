-- Maps an HGSS area's raw light type to one of the five field-light profiles and
-- its NitroFS source path. The profiles are plain-text tables the field engine
-- reads to drive time-of-day lighting; FieldLightProfile parses them. The area
-- light-type -> profile mapping is recovered from the pret/pokeheartgold field
-- initialization path. Pure domain module: no love, no ROM access -- callers read
-- the returned path through RomFs:readSourcePath.

local HgssFieldLighting = {}

-- profileId -> NitroFS source path (zero-based, matching the field engine order).
local PATHS = {
  [0] = "data/area00light.txt",
  [1] = "data/area01light.txt",
  [2] = "data/area02light.txt",
  [3] = "data/dun20_01light.txt",
  [4] = "data/dun20_02light.txt",
}

-- AreaData.lightTypeRaw -> profileId. `secondDungeon` is the optional field
-- condition that substitutes the second dungeon profile for the first; it is a
-- caller-supplied flag, never a map-id branch, so no target-specific logic lives
-- here.
function HgssFieldLighting.profileIdForLightType(lightTypeRaw, secondDungeon)
  if lightTypeRaw == 0 then return 1 end
  if lightTypeRaw == 1 then return 0 end
  if lightTypeRaw == 2 then return secondDungeon and 4 or 3 end
  return 0
end

function HgssFieldLighting.pathForProfile(profileId)
  local path = PATHS[profileId]
  assert(path, "no field-light profile for id " .. tostring(profileId))
  return path
end

-- Convenience: resolve a raw light type straight to { profileId, sourcePath }.
function HgssFieldLighting.resolve(lightTypeRaw, secondDungeon)
  local profileId = HgssFieldLighting.profileIdForLightType(lightTypeRaw, secondDungeon)
  return { profileId = profileId, sourcePath = HgssFieldLighting.pathForProfile(profileId) }
end

HgssFieldLighting.PATHS = PATHS

return HgssFieldLighting
