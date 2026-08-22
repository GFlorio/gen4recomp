-- Selects the small set of HGSS transition profiles represented by the field
-- runtime. Trigger mechanics remain separate from map-class profile identity.

local FieldTransitionProfile = {}

FieldTransitionProfile.DOOR = 1
FieldTransitionProfile.HORIZONTAL_STAIRS = 3
FieldTransitionProfile.ORDINARY_INDOOR = 6
FieldTransitionProfile.ORDINARY = 0

function FieldTransitionProfile.select(triggerKind, sourceMap, destinationMap)
  if triggerKind == "door" then
    return FieldTransitionProfile.DOOR
  end
  if sourceMap and destinationMap and sourceMap.scene and destinationMap.scene then
    if sourceMap.scene.type == "indoor" and destinationMap.scene.type == "indoor" then
      return FieldTransitionProfile.ORDINARY_INDOOR
    end
  end
  if triggerKind == "stairs" then
    return FieldTransitionProfile.HORIZONTAL_STAIRS
  end
  return FieldTransitionProfile.ORDINARY
end

return FieldTransitionProfile
