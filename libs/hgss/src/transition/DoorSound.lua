-- Owns the source-selected HGSS door audio mapping. Runtime doors carry only
-- this semantic selector; ROM-specific record decoding remains in romdump.

local DoorSound = {}

local SEQUENCES = {
  [1] = { open = "SEQ_SE_DP_DOOR_OPEN", close = "SEQ_SE_DP_DOOR_CLOSE2" },
  [2] = { open = "SEQ_SE_DP_DOOR10", close = nil },
  [3] = { open = "SEQ_SE_PL_DOOR_OPEN5", close = nil },
  [4] = { open = "SEQ_SE_GS_HIKIDO_OPEN", close = "SEQ_SE_GS_HIKIDO_CLOSE" },
}

function DoorSound.isValid(soundType)
  return type(soundType) == "number" and soundType % 1 == 0 and SEQUENCES[soundType] ~= nil
end

function DoorSound.sequence(soundType, operation)
  assert(operation == "open" or operation == "close", "door sound operation required")
  local record = SEQUENCES[soundType]
  assert(record, "unsupported door sound type " .. tostring(soundType))
  return record[operation]
end

return DoorSound
