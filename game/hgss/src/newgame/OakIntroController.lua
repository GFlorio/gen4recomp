-- Deterministic Oak/profile state machine for ordinary source frames. It owns
-- semantic sequence progression and the unpublished candidate; presentation
-- and host input map into its public semantic operations without deciding
-- transitions.

local NewGame = require("game.hgss.src.newgame.NewGame")
local OakGreetingPolicy = require("game.hgss.src.newgame.OakGreetingPolicy")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class OakIntroControllerOptions
---@field candidate table partial New Game candidate finalized only after profile confirmation
---@field clock { nowLocal: fun(): LocalCivilTime }
---@field audio GameSound
---@field messages table<string, string|table>
---@field assets table?
---@field playerDataContext { charmap: table<string, integer>, frameIndexes: table<integer, boolean> }
---@field randomU32 fun(): number
---@field virtualGlyphs string[]
---@field virtualKeyColumns integer?

---@class OakIntroEvent
---@field kind string
---@field value string
---@field frame integer

---@class OakIntroControllerView
---@field phase string
---@field message string|table|nil
---@field visual string
---@field visualFrameIndex integer
---@field primaryWidget string|nil
---@field revealWidget string|nil
---@field oakBgScrollX number source BG scroll X, 0 centered and -52 shifted
---@field genderCompositionProgress number normalized host composition progress
---@field messageKey string|nil
---@field confirmationChoice { kind: "gender"|"name", selected: integer }?
---@field dialogue { message: string|table|nil, messageKey: string? }?
---@field revealFrameIndex integer|nil
---@field sceneBrightness number
---@field revealBrightness number
---@field revealOpacity number
---@field finalFadeAlpha number black overlay alpha for the final handoff
---@field genderFocus integer
---@field focusTimer integer
---@field focusBlinkDelta number
---@field name string
---@field virtualGlyphFocus integer
---@field virtualKeys table<integer, { kind: string, glyph: string? }>
---@field virtualKeyColumns integer
---@field nameInputEnabled boolean
---@field sourceFrames integer
---@field events OakIntroEvent[]

---@class OakIntroController
---@field new fun(options: OakIntroControllerOptions): OakIntroController
---@field private _candidate table
---@field private _clock LocalClock
---@field private _audio GameSound
---@field private _messages table<string, string|table>
---@field private _assets table
---@field private _playerDataContext { charmap: table<string, integer>, frameIndexes: table<integer, boolean> }
---@field private _randomU32 fun(): number
---@field private _virtualGlyphs string[]
---@field private _virtualKeyColumns integer
---@field private _virtualFocus integer
---@field private _phase string
---@field private _timer integer
---@field private _started boolean
---@field private _disposed boolean
---@field private _sourceFrames integer
---@field private _message string|table|nil
---@field private _messageKey string|nil
---@field private _confirmationChoice { kind: "gender"|"name", selected: integer }?
---@field private _visual string
---@field private _visualFrameIndex integer
---@field private _visualFrameTimer integer?
---@field private _sceneBrightness integer
---@field private _revealBrightness integer
---@field private _revealOpacity integer
---@field private _finalFadeAlpha number
---@field private _revealFrameIndex integer|nil
---@field private _revealFrameTimer integer|nil
---@field private _revealWidget string|nil
---@field private _genderSelection integer
---@field private _name string
---@field private _oakBgScrollX number source BG scroll X, 0 centered and -52 shifted
---@field private _genderCompositionProgress number normalized host composition progress
---@field private _genderCompositionTimer integer
---@field private _result table|nil
---@field private _events OakIntroEvent[]
---@field tick fun(self: OakIntroController, frames: integer)
---@field start fun(self: OakIntroController): boolean
---@field press fun(self: OakIntroController, action: string): boolean
---@field inputText fun(self: OakIntroController, text: string): boolean
---@field deleteGlyph fun(self: OakIntroController): boolean
---@field view fun(self: OakIntroController): OakIntroControllerView
---@field candidate fun(self: OakIntroController): table
---@field result fun(self: OakIntroController): table|nil
---@field dispose fun(self: OakIntroController)
---@field messageCompleted fun(self: OakIntroController, key: string): boolean
local OakIntroController = {}
OakIntroController.__index = OakIntroController

local GREETING_WAIT = 40
local MUSIC_FADE_FRAMES = 6
local OAK_REVEAL_WAIT = 30
local OAK_SLIDE_FRAMES = 26
local BALL_OPEN_WAIT = 30
local MARILL_CRY_WAIT = 40
local MARILL_HIDE_WAIT = 30
local NAME_LAUNCH_WAIT = 40
local FINAL_FULL_ART_HOLD = 30
local FINAL_FADE_FRAMES = 1
local OAK_BG_SCROLL_END_X = -52
local GENDER_COMPOSITION_FRAMES = 26
local REVEAL_ANIMATION_UNITS_PER_SOURCE_FRAME = 2
local DEFAULT_PROFILE_NAMES = { [0] = "Ethan", [1] = "Lyra" }

local function focusBlinkDelta(timer)
  local deg = (timer % 36) * 10
  local rad = math.rad(deg)
  local value = math.sin(rad) * 8
  if value >= 0 then
    return math.floor(value + 0.5)
  else
    return math.ceil(value - 0.5)
  end
end

local function requireMessage(messages, key)
  local message = messages[key]
  assert(type(message) == "string" or type(message) == "table", "generated Oak message is missing: " .. key)
  return message
end

local function requireClock(clock)
  assert(type(clock) == "table" and type(clock.nowLocal) == "function", "Oak intro requires a local clock")
end

local function requireAudio(audio)
  assert(
    type(audio) == "table"
      and type(audio.playMusic) == "function"
      and type(audio.stopMusic) == "function"
      and type(audio.fadeMusicOut) == "function"
      and type(audio.play) == "function"
      and type(audio.playCry) == "function"
      and type(audio.updateSoundFrame) == "function"
      and type(audio.isMusicFadeActive) == "function",
    "Oak intro requires the core game audio facade"
  )
end

local function isBlankName(name)
  for glyph in Utf8Glyphs.iter(name) do
    if glyph ~= " " then
      return false
    end
  end
  return true
end

local function validateTickCount(frames)
  assert(type(frames) == "number" and frames % 1 == 0 and frames >= 0, "Oak tick count must be a non-negative integer")
end

---@param index number
---@return integer
local function assertSelectionIndex(index)
  assert(
    type(index) == "number"
      and index == index
      and index ~= math.huge
      and index ~= -math.huge
      and index == math.floor(index),
    "selection index must be a finite integer"
  )
  assert(index >= 0 and index < 2, "selection index is out of range")
  ---@cast index integer
  return index
end

local function framesFor(assets, visual)
  assets = assets.widgets or assets
  local asset = assets[visual]
  return asset and asset.frames or nil
end

local function appendGlyphs(text)
  local glyphs = {}
  for glyph in Utf8Glyphs.iter(text) do
    glyphs[#glyphs + 1] = glyph
  end
  return glyphs
end

---@param options table
---@return OakIntroController
function OakIntroController.new(options)
  assert(type(options) == "table", "OakIntroController requires options")
  assert(
    type(options.candidate) == "table" and options.candidate.playerData == nil,
    "Oak intro requires a partial candidate"
  )
  requireClock(options.clock)
  requireAudio(options.audio)
  assert(type(options.messages) == "table", "Oak intro requires generated messages")
  assert(
    type(options.playerDataContext) == "table" and type(options.playerDataContext.charmap) == "table",
    "Oak intro requires a generated font charmap"
  )
  assert(type(options.randomU32) == "function", "Oak intro requires a trainer ID provider")
  assert(
    type(options.virtualGlyphs) == "table" and #options.virtualGlyphs > 0,
    "Oak intro requires virtual keyboard glyphs"
  )

  return setmetatable({
    _candidate = options.candidate,
    _clock = options.clock,
    _audio = options.audio,
    _messages = options.messages,
    _assets = options.assets or {},
    _playerDataContext = options.playerDataContext,
    _randomU32 = options.randomU32,
    _virtualGlyphs = options.virtualGlyphs,
    _virtualKeyColumns = math.max(1, math.min(10, options.virtualKeyColumns or 10)),
    _virtualFocus = 1,
    _phase = "opening_wait",
    _timer = GREETING_WAIT,
    _started = false,
    _disposed = false,
    _sourceFrames = 0,
    _message = nil,
    _messageKey = nil,
    _confirmationChoice = nil,
    _visual = "background",
    _visualFrameIndex = 1,
    _visualFrameTimer = nil,
    _sceneBrightness = 0,
    _revealBrightness = 0,
    _revealOpacity = 16,
    _finalFadeAlpha = 0,
    _revealFrameIndex = nil,
    _revealFrameTimer = nil,
    _revealWidget = nil,
    _genderSelection = 0,
    _focusTimer = 0,
    _focusBlinkDelta = 0,
    _name = "",
    _oakBgScrollX = 0,
    _genderCompositionProgress = 0,
    _genderCompositionTimer = 0,
    _result = nil,
    _events = {},
  }, OakIntroController)
end

function OakIntroController:_setVisual(visual)
  self._visual = visual
  self._visualFrameIndex = 1
  local frames = framesFor(self._assets, visual)
  self._visualFrameTimer = frames and assert(frames[1].duration) or nil
end

function OakIntroController:_advanceVisual()
  local frames =
    assert(framesFor(self._assets, self._visual), "generated visual animation is missing: " .. self._visual)
  self._visualFrameTimer = assert(self._visualFrameTimer) - 1
  if self._visualFrameTimer > 0 then
    return false
  end
  if self._visualFrameIndex == #frames then
    if self._phase == "marill_cry_wait" then
      self._visualFrameIndex = 1
    else
      return true
    end
  else
    self._visualFrameIndex = self._visualFrameIndex + 1
  end
  self._visualFrameTimer = assert(frames[self._visualFrameIndex].duration)
  return false
end

function OakIntroController:_startReveal(visual)
  local frames = framesFor(self._assets, visual)
  assert(frames ~= nil and #frames > 0, "generated Oak animation is missing: " .. visual)
  self._revealWidget = visual
  self._revealFrameIndex = 1
  self._revealFrameTimer = assert(frames[1].duration)
end

function OakIntroController:_advanceReveal(loop)
  local visual = assert(self._revealWidget)
  local frames = framesFor(self._assets, visual)
  assert(frames ~= nil and #frames > 0, "generated Oak animation is missing: " .. visual)

  local units = REVEAL_ANIMATION_UNITS_PER_SOURCE_FRAME
  while units > 0 do
    local frameRemaining = assert(self._revealFrameTimer)
    if units < frameRemaining then
      self._revealFrameTimer = frameRemaining - units
      return false
    end

    units = units - frameRemaining
    if self._revealFrameIndex == #frames then
      if not loop then
        return true
      end
      self._revealFrameIndex = 1
    else
      self._revealFrameIndex = self._revealFrameIndex + 1
    end
    self._revealFrameTimer = assert(frames[self._revealFrameIndex].duration)
  end

  return false
end

function OakIntroController:_event(kind, value)
  self._events[#self._events + 1] = { kind = kind, value = value, frame = self._sourceFrames }
end

function OakIntroController:_setMessage(key)
  self._message = requireMessage(self._messages, key)
  self._messageKey = key
  self._confirmationChoice = nil
  self:_event("message", key)
end

function OakIntroController:_startAppearance()
  self:_startReveal("marill_appear")
  self._revealBrightness = 16
  self._phase = "marill_appear"
end

function OakIntroController:_startCry()
  self:_startReveal("marill")
  self._revealBrightness = 0
  self._audio:playCry(184, 0)
  self:_event("marill_appears", "marill")
  self._phase = "marill_cry_wait"
  self._timer = MARILL_CRY_WAIT
end

function OakIntroController:_setVirtualKeyAction(kind)
  if kind == "delete" then
    return self:deleteGlyph()
  elseif kind == "confirm" then
    return self:press("submit")
  end
  return false
end

function OakIntroController:_virtualKeys()
  local keys = {}
  for _, glyph in ipairs(self._virtualGlyphs) do
    keys[#keys + 1] = { kind = "glyph", glyph = glyph }
  end
  keys[#keys + 1] = { kind = "delete" }
  keys[#keys + 1] = { kind = "confirm" }
  return keys
end

function OakIntroController:_finish()
  local finalized, failure = NewGame.finalize(self._candidate, {
    name = self._name,
    gender = self._genderSelection,
  }, {
    randomU32 = self._randomU32,
    playerDataContext = self._playerDataContext,
  })
  assert(finalized, failure and failure.message or "Oak profile finalization failed")
  self._result = finalized
  self._phase = "complete"
  self:_event("handoff", finalized.saveId)
end

function OakIntroController:_stepFrame()
  self._sourceFrames = self._sourceFrames + 1
  self._audio:updateSoundFrame()
  if self._phase == "gender_composition_transition" then
    self._genderCompositionTimer = self._genderCompositionTimer - 1
    self._genderCompositionProgress = (GENDER_COMPOSITION_FRAMES - self._genderCompositionTimer)
      / GENDER_COMPOSITION_FRAMES
    if self._genderCompositionTimer == 0 then
      self._genderCompositionProgress = 1
      self._phase = "gender_select"
      self._focusTimer = 0
      self._focusBlinkDelta = 0
    end
    return
  elseif self._phase == "gender_composition_exit" then
    self._genderCompositionTimer = self._genderCompositionTimer - 1
    self._genderCompositionProgress = self._genderCompositionTimer / GENDER_COMPOSITION_FRAMES
    if self._genderCompositionTimer == 0 then
      self._genderCompositionProgress = 0
      self._phase = "name_confirm"
      self:_setVisual("oak")
      self:_setMessage(self._genderSelection == 0 and "profile.name_confirm.male" or "profile.name_confirm.female")
    end
    return
  end
  local startedCry = false
  if self._phase == "shrink_animation" then
    if self:_advanceVisual() then
      self:_finish()
    end
    return
  elseif self._phase == "ball_open_wait" then
    self:_advanceReveal(true)
  elseif self._phase == "scene_flash" then
    self._sceneBrightness = math.max(0, self._sceneBrightness - 4)
    if self._sceneBrightness == 0 then
      self:_startAppearance()
    end
  elseif self._phase == "marill_appear" then
    if self:_advanceReveal(false) then
      self._phase = "marill_brightness_fade"
      self._revealBrightness = 16
    end
  elseif self._phase == "marill_brightness_fade" then
    self._revealBrightness = math.max(0, self._revealBrightness - 1)
    if self._revealBrightness == 0 then
      self:_startCry()
      startedCry = true
    end
  elseif self._revealWidget ~= nil and not startedCry then
    -- Marill (or another reveal widget) keeps looping its idle animation for
    -- every remaining source phase in which it is still the visible reveal,
    -- including dialogue waits such as oak_live_alongside.
    self:_advanceReveal(true)
  end
  if self._phase == "opening_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      local civilTime = self._clock:nowLocal()
      self:_setMessage(OakGreetingPolicy.messageKey(civilTime))
      self._phase = "greeting"
      self:_setVisual("background")
    end
  elseif self._phase == "fade_wait" then
    self._timer = self._timer - 1
    if self._timer <= 0 and not self._audio:isMusicFadeActive() then
      self._audio:stopMusic()
      self._audio:playMusic("SEQ_GS_STARTING2")
      self._phase = "oak_reveal_wait"
      self._timer = OAK_REVEAL_WAIT
      self:_setVisual("oak")
      self:_event("oak_revealed", "oak")
    end
  elseif self._phase == "oak_reveal_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._phase = "oak_welcome"
      self:_setMessage("oak.welcome")
    end
  elseif self._phase == "oak_slide_right" or self._phase == "oak_slide_left" then
    self._timer = self._timer - 1
    local progress = (OAK_SLIDE_FRAMES - self._timer) / OAK_SLIDE_FRAMES
    if self._phase == "oak_slide_right" then
      self._oakBgScrollX = OAK_BG_SCROLL_END_X * progress
    else
      self._oakBgScrollX = OAK_BG_SCROLL_END_X * (1 - progress)
    end
    if self._timer == 0 then
      if self._phase == "oak_slide_right" then
        self._oakBgScrollX = OAK_BG_SCROLL_END_X
        self._phase = "oak_world_inhabited"
        self:_setMessage("oak.world_inhabited")
      else
        self._oakBgScrollX = 0
        self._phase = "oak_tell_about_yourself"
        self:_setMessage("oak.tell_about_yourself")
      end
    end
  elseif self._phase == "ball_open_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self:_event("ball_flash", "opening")
      self._audio:play("SEQ_SE_DP_BOWA2")
      self._sceneBrightness = 16
      self._phase = "scene_flash"
    end
  elseif self._phase == "marill_cry_wait" and not startedCry then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._phase = "oak_live_alongside"
      self:_setVisual("oak")
      self:_setMessage("oak.live_alongside")
    end
  elseif self._phase == "marill_hide" then
    self._revealOpacity = math.max(0, self._revealOpacity - 1)
    if self._revealOpacity == 0 then
      self._revealWidget = nil
      self._revealFrameIndex = nil
      self._revealFrameTimer = nil
      self._phase = "marill_hide_wait"
      self._timer = MARILL_HIDE_WAIT
    end
  elseif self._phase == "marill_hide_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._phase = "oak_slide_left"
      self._timer = OAK_SLIDE_FRAMES
      self:_setVisual("oak")
      self:_event("oak_slide", "left")
    end
  elseif self._phase == "name_launch_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self:_enterNameEditor()
    end
  elseif self._phase == "final_fade_out" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._finalFadeAlpha = 1
      self:_setVisual(self._genderSelection == 0 and "male" or "female")
      self._phase = "final_full_art_fade_in"
      self._timer = FINAL_FADE_FRAMES
    end
  elseif self._phase == "final_full_art_fade_in" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._finalFadeAlpha = 0
      self._phase = "final_full_art_hold"
      self._timer = FINAL_FULL_ART_HOLD
    end
  elseif self._phase == "final_full_art_hold" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._audio:play("SEQ_SE_GS_HERO_SHUKUSHOU")
      self:_setVisual(self._genderSelection == 0 and "shrink_male" or "shrink_female")
      if framesFor(self._assets, self._visual) == nil then
        self:_finish()
      else
        self._phase = "shrink_animation"
      end
    end
  elseif self._phase == "gender_select" then
    self._focusBlinkDelta = focusBlinkDelta(self._focusTimer)
    self._focusTimer = self._focusTimer + 1
  end
end

---@param frames integer
function OakIntroController:tick(frames)
  validateTickCount(frames)
  if self._disposed or not self._started then
    return
  end
  for _ = 1, frames do
    if self._phase == "complete" then
      break
    end
    self:_stepFrame()
  end
end

function OakIntroController:start()
  assert(not self._disposed, "Oak intro is disposed")
  if self._started then
    return false
  end
  self._started = true
  self._audio:playMusic("SEQ_GS_STARTING")
  self:_event("started", "SEQ_GS_STARTING")
  return true
end

function OakIntroController:_enterNameEditor()
  self._name = ""
  self._virtualFocus = 1
  self._phase = "name_edit"
  self:_setVisual("background")
  self:_event("name_editor", "opened")
end

function OakIntroController:_playSelectionEffect()
  self._audio:play("SEQ_SE_DP_SELECT")
end

function OakIntroController:_focusGender(index)
  index = assertSelectionIndex(index)
  local changed = self._genderSelection ~= index
  self._genderSelection = index
  if changed then
    self._focusTimer = 0
    self._focusBlinkDelta = 0
    self:_playSelectionEffect()
  end
  return changed
end

function OakIntroController:_activateGender(index)
  assert(self._phase == "gender_select", "gender activation is only valid during selection")
  index = assertSelectionIndex(index)
  self._genderSelection = index
  self._focusTimer = 0
  self._focusBlinkDelta = 0
  self:_playSelectionEffect()
  self._phase = "gender_confirm"
  self:_setMessage(index == 0 and "profile.gender_confirm.male" or "profile.gender_confirm.female")
  return true
end

function OakIntroController:_resolveConfirmation(selected)
  assert(self._confirmationChoice ~= nil, "Oak confirmation choice is not active")
  selected = assertSelectionIndex(selected)
  self:_playSelectionEffect()
  local kind = self._confirmationChoice.kind
  self._confirmationChoice = nil
  if kind == "gender" then
    if selected == 0 then
      self._phase = "name_prompt"
      self:_setMessage("profile.name_prompt")
    else
      self._phase = "gender_question"
      self:_setMessage("profile.gender_question")
    end
  elseif kind == "name" then
    if selected == 0 then
      self._phase = "final_dialogue"
      self:_setMessage("profile.final")
    else
      self._phase = "gender_question"
      self:_setMessage("profile.gender_question")
    end
  else
    error("unknown Oak confirmation kind: " .. tostring(kind), 0)
  end
  return true
end

function OakIntroController:press(action)
  assert(type(action) == "string", "Oak semantic action must be a string")
  if self._disposed or not self._started or self._phase == "complete" then
    return false
  end
  if self._message ~= nil then
    return false
  end
  if self._confirmationChoice then
    local kind = self._confirmationChoice.kind
    local vertical = action == "up" or action == "down"
    local horizontal = action == "left" or action == "right"
    if (kind == "gender" and vertical) or (kind == "name" and horizontal) then
      local index = (action == "up" or action == "left") and 0 or 1
      local changed = self._confirmationChoice.selected ~= index
      self._confirmationChoice.selected = assertSelectionIndex(index)
      if changed then
        self:_playSelectionEffect()
      end
      return true
    end
    if action == "confirm" then
      return self:_resolveConfirmation(self._confirmationChoice.selected)
    end
    if action == "yes" then
      return self:_resolveConfirmation(0)
    end
    if action == "cancel" or action == "no" then
      return self:_resolveConfirmation(1)
    end
    return false
  end
  if self._phase == "gender_select" and (action == "male" or action == "female") then
    return self:_activateGender(action == "male" and 0 or 1)
  end
  if action == "left" and self._phase == "gender_select" then
    self:_focusGender(0)
  elseif action == "right" and self._phase == "gender_select" then
    self:_focusGender(1)
  elseif
    self._phase == "name_edit" and (action == "left" or action == "right" or action == "up" or action == "down")
  then
    local count = #self._virtualGlyphs + 2
    local columns = self._virtualKeyColumns
    local step = action == "left" and -1 or action == "right" and 1 or action == "up" and -columns or columns
    self._virtualFocus = ((self._virtualFocus - 1 + step) % count) + 1
    self._audio:play("SEQ_SE_DP_SELECT")
  elseif action == "confirm" and self._phase == "name_edit" then
    local key = self:_virtualKeys()[self._virtualFocus]
    if key.kind == "glyph" then
      return self:inputText(key.glyph)
    end
    return self:_setVirtualKeyAction(key.kind)
  elseif (action == "confirm" or action == "yes") and self._phase == "greeting" then
    self._audio:fadeMusicOut({ target = 0, durationTicks = MUSIC_FADE_FRAMES })
    self._phase = "fade_wait"
    self._timer = MUSIC_FADE_FRAMES
  elseif (action == "confirm" or action == "yes") and self._phase == "oak_welcome" then
    self._phase = "oak_slide_right"
    self._timer = OAK_SLIDE_FRAMES
    self:_event("oak_slide", "right")
  elseif (action == "confirm" or action == "yes") and self._phase == "oak_world_inhabited" then
    self._phase = "ball_open_wait"
    self._timer = BALL_OPEN_WAIT
    self:_startReveal("ball_open")
    self:_event("ball_opened", "ball_open")
  elseif (action == "confirm" or action == "yes") and self._phase == "oak_live_alongside" then
    self._phase = "marill_hide"
    self._revealOpacity = 16
    self:_setVisual("oak")
    self:_event("marill_hidden", "marill")
  elseif (action == "confirm" or action == "yes") and self._phase == "oak_tell_about_yourself" then
    self._phase = "gender_question"
    self:_setMessage("profile.gender_question")
  elseif (action == "confirm" or action == "yes") and self._phase == "gender_question" then
    if self._genderCompositionProgress < 1 then
      self._phase = "gender_composition_transition"
      self._genderCompositionTimer = GENDER_COMPOSITION_FRAMES
    else
      self._phase = "gender_select"
      self._focusTimer = 0
      self._focusBlinkDelta = 0
    end
  elseif (action == "confirm" or action == "yes") and self._phase == "gender_select" then
    return self:_activateGender(self._genderSelection)
  elseif (action == "confirm" or action == "yes") and self._phase == "name_prompt" then
    self._phase = "name_launch_wait"
    self._timer = NAME_LAUNCH_WAIT
  elseif (action == "submit" or action == "confirm" or action == "yes") and self._phase == "name_edit" then
    local glyphs = appendGlyphs(self._name)
    if #glyphs <= 7 then
      if isBlankName(self._name) then
        self._name = assert(DEFAULT_PROFILE_NAMES[self._genderSelection])
      end
      if #appendGlyphs(self._name) >= 1 then
        self._phase = "gender_composition_exit"
        self._genderCompositionTimer = GENDER_COMPOSITION_FRAMES
        self:_setVisual("oak")
      end
    end
  elseif (action == "confirm" or action == "yes") and self._phase == "final_dialogue" then
    self._phase = "final_fade_out"
    self._timer = FINAL_FADE_FRAMES
    self._finalFadeAlpha = 0
    self:_setVisual("background")
    self:_event("final_handoff_started", "player")
  else
    return false
  end
  return true
end

---@param text string
---@return boolean
function OakIntroController:inputText(text)
  assert(type(text) == "string", "Oak text input must be a string")
  if self._disposed or self._phase ~= "name_edit" then
    return false
  end
  local incoming = appendGlyphs(text)
  for _, glyph in ipairs(incoming) do
    if self._playerDataContext.charmap[glyph] == nil then
      return false
    end
  end
  local current = appendGlyphs(self._name)
  if #current + #incoming > 7 then
    return false
  end
  self._name = self._name .. text
  return true
end

---@return boolean
function OakIntroController:deleteGlyph()
  if self._disposed or self._phase ~= "name_edit" then
    return false
  end
  local glyphs = appendGlyphs(self._name)
  glyphs[#glyphs] = nil
  self._name = table.concat(glyphs)
  return true
end

---@return table
function OakIntroController:view()
  local virtualKeys = self:_virtualKeys()
  local primaryWidget ---@type string|nil
  primaryWidget = self._visual
  if primaryWidget == "background" then
    primaryWidget = self._phase == "marill_cry_wait" and "oak" or nil
  end
  local dialogue
  if self._message ~= nil then
    dialogue = {
      message = self._message,
      messageKey = assert(self._messageKey),
    }
  end
  return {
    phase = self._phase,
    message = self._message,
    visual = self._visual,
    visualFrameIndex = self._visualFrameIndex,
    sceneBrightness = self._sceneBrightness / 16,
    revealBrightness = self._revealBrightness / 16,
    revealOpacity = self._revealOpacity / 16,
    genderFocus = self._genderSelection,
    focusTimer = self._focusTimer,
    focusBlinkDelta = self._focusBlinkDelta,
    name = self._name,
    virtualGlyphFocus = self._virtualFocus,
    virtualKeys = virtualKeys,
    virtualKeyColumns = self._virtualKeyColumns,
    nameInputEnabled = self._phase == "name_edit",
    sourceFrames = self._sourceFrames,
    events = self._events,
    messageKey = self._messageKey,
    confirmationChoice = self._confirmationChoice and {
      kind = self._confirmationChoice.kind,
      selected = self._confirmationChoice.selected,
    } or nil,
    dialogue = dialogue,
    primaryWidget = primaryWidget,
    revealWidget = self._revealWidget,
    revealFrameIndex = self._revealFrameIndex,
    oakBgScrollX = self._oakBgScrollX,
    genderCompositionProgress = self._genderCompositionProgress,
    finalFadeAlpha = self._finalFadeAlpha,
  }
end

---@param key string
---@return boolean
function OakIntroController:messageCompleted(key)
  assert(key == self._messageKey, "Oak dialogue completion is stale")
  assert(self._message ~= nil, "Oak dialogue completion has no active message")
  self._message = nil
  self._messageKey = nil
  if self._phase == "gender_confirm" or self._phase == "name_confirm" then
    self._confirmationChoice = {
      kind = self._phase == "gender_confirm" and "gender" or "name",
      selected = 0,
    }
    return true
  end
  return self:press("confirm")
end

function OakIntroController:candidate()
  return self._candidate
end

function OakIntroController:result()
  return self._result
end

function OakIntroController:dispose()
  if self._disposed then
    return
  end
  self._disposed = true
  self._audio:stopMusic()
end

return OakIntroController
