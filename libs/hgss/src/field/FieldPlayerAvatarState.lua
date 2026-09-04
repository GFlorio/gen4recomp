-- Owns the player's avatar transition state: one durable mode, one displayed
-- visual, the pending semantic transition set applied in fixed source order,
-- and the mutable surf presentation phase. It never loads assets, plays
-- audio, or mutates the player: applying returns the final sprite and the
-- ordered sound intents, and the composer materializes them through the
-- existing visual and audio collaborators. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local FieldErrors = require("libs.hgss.src.field.FieldErrors")

-- The fourteen supported semantic transitions in fixed source application order,
-- independent of queue insertion order.
local TRANSITION_ORDER = {
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

local TRANSITION_SET = {}
for _, name in ipairs(TRANSITION_ORDER) do
  TRANSITION_SET[name] = true
end

-- The only states kept across save/reload; every other visual is temporary.
local DURABLE_SET = {
  walking = true,
  cycling = true,
  surfing = true,
  rocket = true,
}

local CYCLING_SOUND = "SEQ_SE_DP_JITENSYA"

---@class FieldPlayerAvatarState.Options
---@field capability { id: string, gender: integer, states: table<string, integer> }
---@field surfPresentation table normalized surf presentation definition
---@field initialState string? durable boot state, defaults to walking

---@class FieldPlayerAvatarState
---@field _capability table
---@field _surf table
---@field _durable string
---@field _visual string
---@field _pending table<string, boolean>
---@field _surfActive boolean
---@field _oscY number
---@field _oscDelta number
---@field _playerOffset { x: number, y: number, z: number }
---@field _attachmentY number
local FieldPlayerAvatarState = {}
FieldPlayerAvatarState.__index = FieldPlayerAvatarState

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isOffset(value)
  return type(value) == "table" and isFiniteNumber(value.x) and isFiniteNumber(value.y) and isFiniteNumber(value.z)
end

local function checkCapability(capability)
  assert(type(capability) == "table", "the avatar transition owner requires a capability")
  assert(type(capability.id) == "string" and capability.id ~= "", "the avatar capability requires an id")
  assert(capability.gender == 0 or capability.gender == 1, "the avatar capability requires a playable gender")
  assert(type(capability.states) == "table", "the avatar capability requires a visual-state map")
  local count = 0
  for state, spriteId in pairs(capability.states) do
    assert(TRANSITION_SET[state] == true, "the avatar capability carries an unknown visual state " .. tostring(state))
    assert(
      type(spriteId) == "number" and spriteId >= 0 and spriteId % 1 == 0,
      "the avatar capability requires a compiled spriteId for " .. tostring(state)
    )
    count = count + 1
  end
  assert(count == #TRANSITION_ORDER, "the avatar capability must map every visual state")
end

local function checkSurfPresentation(presentation)
  assert(type(presentation) == "table", "the avatar transition owner requires a surf presentation definition")
  assert(isOffset(presentation.initialPlayerOffset), "the surf presentation requires an initial player offset")
  assert(isOffset(presentation.playerBaseOffset), "the surf presentation requires a player base offset")
  assert(isOffset(presentation.attachmentBaseOffset), "the surf presentation requires an attachment base offset")
  local oscillator = presentation.oscillator
  assert(type(oscillator) == "table", "the surf presentation requires an oscillator")
  assert(
    isFiniteNumber(oscillator.initialY)
      and isFiniteNumber(oscillator.minY)
      and isFiniteNumber(oscillator.maxY)
      and isFiniteNumber(oscillator.stepY),
    "the surf oscillator requires finite bounds and step"
  )
  assert(oscillator.stepY > 0, "the surf oscillator step must advance")
  assert(oscillator.minY <= oscillator.maxY, "the surf oscillator bounds are inverted")
  assert(
    oscillator.initialY >= oscillator.minY and oscillator.initialY <= oscillator.maxY,
    "the surf oscillator must start inside its bounds"
  )
  local yaw = presentation.yawDegrees
  assert(type(yaw) == "table", "the surf presentation requires a facing yaw map")
  assert(
    isFiniteNumber(yaw.north) and isFiniteNumber(yaw.south) and isFiniteNumber(yaw.west) and isFiniteNumber(yaw.east),
    "the surf presentation requires a yaw for every facing"
  )
end

---@param opts FieldPlayerAvatarState.Options
---@return FieldPlayerAvatarState
function FieldPlayerAvatarState.new(opts)
  assert(type(opts) == "table", "the avatar transition owner requires options")
  checkCapability(opts.capability)
  checkSurfPresentation(opts.surfPresentation)
  local initialState = opts.initialState or "walking"
  assert(DURABLE_SET[initialState] == true, "the avatar boot state must be durable: " .. tostring(initialState))
  local self = setmetatable({
    _capability = opts.capability,
    _surf = opts.surfPresentation,
    _durable = initialState,
    _visual = initialState,
    _pending = {},
    _surfActive = false,
    _oscY = 0,
    _oscDelta = 0,
    _playerOffset = { x = 0, y = 0, z = 0 },
    _attachmentY = 0,
  }, FieldPlayerAvatarState)
  if initialState == "surfing" then
    self:_restartSurf()
  end
  return self
end

-- Queue one semantic transition. Queueing is set-union: repeats before apply
-- stay one pending transition.
---@param name string
function FieldPlayerAvatarState:queueTransition(name)
  if TRANSITION_SET[name] ~= true then
    Errors.raise(FieldErrors.PLAYER_AVATAR_INVALID, "unknown avatar transition", { transition = name })
  end
  self._pending[name] = true
end

-- Destroy any prior surf phase and restart at the source creation phase.
function FieldPlayerAvatarState:_restartSurf()
  local presentation = self._surf
  local initial = presentation.initialPlayerOffset
  self._surfActive = true
  self._oscY = presentation.oscillator.initialY
  self._oscDelta = presentation.oscillator.stepY
  self._playerOffset = { x = initial.x, y = initial.y, z = initial.z }
  self._attachmentY = presentation.attachmentBaseOffset.y + self._oscY
end

local function deactivateSurf(working)
  working.surfActive = false
  working.playerOffset = { x = 0, y = 0, z = 0 }
  working.attachmentY = 0
end

-- Apply every pending transition in fixed source order, then clear the set.
-- The result is computed into locals first so a missing visual fails before
-- any state commits or the queue is consumed. Returns the final sprite, whether
-- it changed, and the ordered sound intents for the composer to play.
---@return { spriteId: integer, spriteChanged: boolean, sounds: string[] }
function FieldPlayerAvatarState:applyTransitions()
  local states = self._capability.states
  local beforeSpriteId = states[self._visual]
  -- Validate every selected visual before committing anything.
  for _, name in ipairs(TRANSITION_ORDER) do
    if self._pending[name] == true then
      local spriteId = states[name]
      if type(spriteId) ~= "number" then
        Errors.raise(
          FieldErrors.PLAYER_AVATAR_INVALID,
          "the avatar capability is missing a visual state",
          { visual = name }
        )
      end
    end
  end
  local working = {
    durable = self._durable,
    visual = self._visual,
    surfActive = self._surfActive,
    oscY = self._oscY,
    oscDelta = self._oscDelta,
    playerOffset = { x = self._playerOffset.x, y = self._playerOffset.y, z = self._playerOffset.z },
    attachmentY = self._attachmentY,
    surfRestart = false,
    sounds = {},
  }
  for _, name in ipairs(TRANSITION_ORDER) do
    if self._pending[name] == true then
      if name == "walking" or name == "cycling" or name == "surfing" or name == "rocket" then
        working.durable = name
        working.visual = name
        if name == "surfing" then
          working.surfRestart = true
        else
          deactivateSurf(working)
          working.surfRestart = false
        end
        if name == "cycling" then
          working.sounds[#working.sounds + 1] = CYCLING_SOUND
        end
      else
        working.visual = name
      end
    end
  end
  self._durable = working.durable
  self._visual = working.visual
  if working.surfRestart then
    self:_restartSurf()
  else
    self._surfActive = working.surfActive
    if not working.surfActive then
      self._playerOffset = working.playerOffset
      self._attachmentY = working.attachmentY
      self._oscY = 0
      self._oscDelta = 0
    end
  end
  for name in pairs(self._pending) do
    self._pending[name] = nil
  end
  local spriteId = states[self._visual]
  return { spriteId = spriteId, spriteChanged = spriteId ~= beforeSpriteId, sounds = working.sounds }
end

-- Advance the surf oscillator one fixed tick. Runs even while the world is
-- otherwise frozen; never on host render delta.
function FieldPlayerAvatarState:updateFixed()
  if not self._surfActive then
    return
  end
  local oscillator = self._surf.oscillator
  local height = self._oscY + self._oscDelta
  local delta = self._oscDelta
  if height >= oscillator.maxY then
    height = oscillator.maxY
    delta = -oscillator.stepY
  elseif height <= oscillator.minY then
    height = oscillator.minY
    delta = oscillator.stepY
  end
  self._oscY = height
  self._oscDelta = delta
  local base = self._surf.playerBaseOffset
  self._playerOffset = { x = base.x, y = base.y + height, z = base.z }
  self._attachmentY = self._surf.attachmentBaseOffset.y + height
end

---@return integer
function FieldPlayerAvatarState:currentSpriteId()
  return self._capability.states[self._visual]
end

-- Presentation-only offsets plus surf status. Carries no logical coordinates.
---@return { playerOffset: { x: number, y: number, z: number }, surf: { active: boolean, attachmentOffsetY: number } }
function FieldPlayerAvatarState:presentationState()
  return {
    playerOffset = { x = self._playerOffset.x, y = self._playerOffset.y, z = self._playerOffset.z },
    surf = { active = self._surfActive, attachmentOffsetY = self._attachmentY },
  }
end

-- True only with no pending transitions and no temporary visual override.
---@return boolean
function FieldPlayerAvatarState:isStableForSave()
  if self._visual ~= self._durable then
    return false
  end
  for _ in pairs(self._pending) do
    return false
  end
  return true
end

-- Only durable state is serialized; pending and temporary state never are.
---@return { state: string }
function FieldPlayerAvatarState:capture()
  return { state = self._durable }
end

-- Semantic snapshot for tests and debugging. Carries no logical coordinates.
---@return table
function FieldPlayerAvatarState:status()
  local pending = {}
  for name in pairs(self._pending) do
    pending[name] = true
  end
  return {
    durableState = self._durable,
    visualState = self._visual,
    spriteId = self._capability.states[self._visual],
    surfActive = self._surfActive,
    pending = pending,
  }
end

return FieldPlayerAvatarState
