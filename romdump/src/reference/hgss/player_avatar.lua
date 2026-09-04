-- Pinned HGSS player-avatar transition catalog: source-independent visual
-- transitions plus the gendered sprite selected for each visual state.
-- Normalized from pret/pokeheartgold@0985e8718df4f25e64d6507d89c0c97c0d288981
-- src/player_avatar.c (PlayerAvatar_GetSpriteByStateAndGender,
-- Field_PlayerAvatar_ApplyTransitionFlags),
-- asm/overlay_01_021F1AFC.s (the source bit-3 handler), and
-- include/constants/sprites.h. Producer-only; generated output carries
-- semantic state names and compiled sprite IDs, never transition bit
-- positions. Pure data; no love dependency.

---@class PlayerAvatarReference
local PlayerAvatar = {}

-- The supported source-independent transitions in source bit order (bit 0
-- first, with source bit 3 intentionally omitted).
PlayerAvatar.transitionOrder = {
  "walking",
  "cycling",
  "surfing",
  "watering",
  "fishing",
  "poketch",
  "saving",
  "heal",
  "ladder",
  "rocket",
  "rocket_heal",
  "pokeathlon",
  "apricorn_shake",
  "rocket_saving",
}

-- Source bit 3 calls PlayerAvatar_SetFlag1 in the pinned handler. Its
-- movement side effect is not modeled by the runtime, so it remains known but
-- unsupported rather than becoming a visual or successful no-op semantic.
local transitionsByBit = {
  [0] = "walking",
  [1] = "cycling",
  [2] = "surfing",
  [4] = "watering",
  [5] = "fishing",
  [6] = "poketch",
  [7] = "saving",
  [8] = "heal",
  [9] = "ladder",
  [10] = "rocket",
  [11] = "rocket_heal",
  [12] = "pokeathlon",
  [13] = "apricorn_shake",
  [14] = "rocket_saving",
}

-- The fourteen visual states, in transition order.
PlayerAvatar.visualStates = {
  "walking",
  "cycling",
  "surfing",
  "watering",
  "fishing",
  "poketch",
  "saving",
  "heal",
  "ladder",
  "rocket",
  "rocket_heal",
  "pokeathlon",
  "apricorn_shake",
  "rocket_saving",
}

-- The only states kept across save/reload; every other visual is temporary.
PlayerAvatar.durableStates = {
  walking = true,
  cycling = true,
  surfing = true,
  rocket = true,
}

-- Source sprite selected per visual state and gender (0 = male, 1 = female,
-- the validated player-profile values). Every other layer consumes these
-- through `statesForGender`, never by indexing this table.
local spritesByGender = {
  [0] = {
    walking = 0,
    cycling = 21,
    surfing = 178,
    watering = 180,
    fishing = 188,
    poketch = 196,
    saving = 198,
    heal = 200,
    ladder = 248,
    rocket = 258,
    rocket_heal = 260,
    pokeathlon = 407,
    apricorn_shake = 423,
    rocket_saving = 297,
  },
  [1] = {
    walking = 97,
    cycling = 98,
    surfing = 179,
    watering = 181,
    fishing = 189,
    poketch = 197,
    saving = 199,
    heal = 201,
    ladder = 249,
    rocket = 259,
    rocket_heal = 261,
    pokeathlon = 408,
    apricorn_shake = 424,
    rocket_saving = 298,
  },
}

assert(#PlayerAvatar.transitionOrder == 14, "the transition table covers supported visual source bits")
assert(#PlayerAvatar.visualStates == 14, "every supported transition selects a visual")
do
  local durableCount = 0
  for _ in pairs(PlayerAvatar.durableStates) do
    durableCount = durableCount + 1
  end
  assert(durableCount == 4, "exactly four states persist")
  for _, gender in ipairs({ 0, 1 }) do
    local mapped = assert(spritesByGender[gender], "both playable genders map every visual state")
    local count = 0
    for _, state in ipairs(PlayerAvatar.visualStates) do
      local spriteId = mapped[state]
      assert(
        type(spriteId) == "number" and spriteId >= 0 and spriteId % 1 == 0,
        "gender " .. gender .. " state " .. state .. " must select a sprite"
      )
      count = count + 1
    end
    assert(count == #PlayerAvatar.visualStates, "gender " .. gender .. " maps every visual state exactly once")
  end
end

-- A private copy of the gender's visual-state sprite map. Callers own the
-- result; the pinned table is never shared.
---@param gender integer
---@return table<string, integer>
function PlayerAvatar.statesForGender(gender)
  assert(gender == 0 or gender == 1, "player gender is 0 (male) or 1 (female)")
  local mapped = spritesByGender[gender]
  local states = {}
  for _, state in ipairs(PlayerAvatar.visualStates) do
    states[state] = mapped[state]
  end
  return states
end

---@param state string
---@return boolean
function PlayerAvatar.isDurable(state)
  return PlayerAvatar.durableStates[state] == true
end

-- The semantic transitions selected by a raw u16 queue mask, in source bit
-- order, plus selected source bits whose movement side effects are unsupported.
---@param mask integer
---@return string[], integer[]
function PlayerAvatar.transitionsForMask(mask)
  assert(type(mask) == "number" and mask >= 0 and mask <= 0xFFFF and mask % 1 == 0, "queue mask is a u16")
  local selected = {}
  local unsupportedBits = {}
  for bit = 0, 14 do
    if math.floor(mask / (2 ^ bit)) % 2 == 1 then
      local transition = transitionsByBit[bit]
      if transition ~= nil then
        selected[#selected + 1] = transition
      else
        unsupportedBits[#unsupportedBits + 1] = bit
      end
    end
  end
  return selected, unsupportedBits
end

return PlayerAvatar
