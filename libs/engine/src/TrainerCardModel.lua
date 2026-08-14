-- The read-only Trainer Card model: a pure projection of the required
-- FieldPlayerData profile (name, gender, trainerId) plus only other
-- currently authoritative gameplay values. Every other card field is nil
-- as the explicit "not implemented by gameplay" value; nil is never
-- substituted with zero unless HGSS itself presents the absent value as
-- zero. Semantic values only: text formatting, zero-padding of the
-- displayed trainer ID, labels, coordinates, colors, and card-side artwork
-- belong to the generated UI metadata/renderer. Pure domain module: zero
-- requires, no love dependency, no I/O, no ROM structures. The caller
-- (the future Trainer Card application) supplies the same validated
-- FieldPlayerData record FieldRuntime already holds.

local TrainerCardModel = {}

-- Project a validated FieldPlayerData record into the model shape.
-- Programming invariants: the player-data prerequisite makes the three
-- profile fields authoritative, so their absence is a composition fault.
---@param fieldPlayerData table { profile: table, options: table }
---@return table
function TrainerCardModel.new(fieldPlayerData)
  assert(type(fieldPlayerData) == "table", "TrainerCardModel requires a FieldPlayerData record")
  local profile = fieldPlayerData.profile
  assert(type(profile) == "table", "TrainerCardModel requires the FieldPlayerData profile")
  assert(
    profile.name ~= nil and profile.gender ~= nil and profile.trainerId ~= nil,
    "TrainerCardModel requires name, gender, and trainerId from the player profile"
  )
  return {
    name = profile.name,
    gender = profile.gender,
    trainerId = profile.trainerId,
    money = nil,
    playTime = nil,
    badges = nil,
    pokedexOwned = nil,
    stars = nil,
    signature = nil,
  }
end

return TrainerCardModel
