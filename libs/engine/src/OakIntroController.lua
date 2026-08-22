-- Deterministic 60 Hz Oak/profile state machine. It owns semantic sequence
-- progression and the unpublished candidate; presentation and host input map
-- into its public semantic operations without deciding transitions.

local NewGame = require("libs.engine.src.NewGame")
local OakGreetingPolicy = require("libs.engine.src.OakGreetingPolicy")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class OakIntroControllerOptions
---@field candidate table partial New Game candidate finalized only after profile confirmation
---@field clock LocalClock
---@field audio GameSound
---@field messages table<string, string|table>
---@field assets table?
---@field playerDataContext { charmap: table<string, integer>, frameIndexes: table<integer, boolean> }
---@field randomU32 fun(): number
---@field virtualGlyphs string[]

---@class OakIntroEvent
---@field kind string
---@field value string
---@field frame integer

---@class OakIntroControllerView
---@field phase string
---@field message string|table|nil
---@field visual string
---@field genderFocus integer
---@field name string
---@field virtualGlyphFocus integer
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
---@field private _virtualFocus integer
---@field private _phase string
---@field private _timer integer
---@field private _started boolean
---@field private _disposed boolean
---@field private _sourceFrames integer
---@field private _message string|table|nil
---@field private _visual string
---@field private _genderFocus integer
---@field private _name string
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
local OakIntroController = {}
OakIntroController.__index = OakIntroController

local SOURCE_HZ = 60
local GREETING_WAIT = 40
local MUSIC_FADE_FRAMES = 6
local OAK_REVEAL_WAIT = 30
local MARILL_APPEARANCE_WAIT = 30
local MARILL_CRY_WAIT = 40
local SHRINK_WAIT = 30

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

local function validateTickCount(frames)
  assert(type(frames) == "number" and frames % 1 == 0 and frames >= 0, "Oak tick count must be a non-negative integer")
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
    _virtualFocus = 1,
    _phase = "opening_wait",
    _timer = GREETING_WAIT,
    _started = false,
    _disposed = false,
    _sourceFrames = 0,
    _message = nil,
    _visual = "background",
    _genderFocus = 0,
    _name = "",
    _result = nil,
    _events = {},
  }, OakIntroController)
end

function OakIntroController:_event(kind, value)
  self._events[#self._events + 1] = { kind = kind, value = value, frame = self._sourceFrames }
end

function OakIntroController:_setMessage(key)
  self._message = requireMessage(self._messages, key)
  self:_event("message", key)
end

function OakIntroController:_startCry()
  self._visual = "marill"
  self._audio:play("SEQ_SE_DP_BOWA2")
  self._audio:playCry(184, 0)
  self:_event("marill_appears", "marill")
  self._phase = "marill_cry_wait"
  self._timer = MARILL_CRY_WAIT
end

function OakIntroController:_finish()
  local finalized, failure = NewGame.finalize(self._candidate, {
    name = self._name,
    gender = self._genderFocus,
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
  if self._phase == "opening_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      local civilTime = self._clock:nowLocal()
      self:_setMessage(OakGreetingPolicy.messageKey(civilTime))
      self._phase = "greeting"
      self._visual = "background"
    end
  elseif self._phase == "fade_wait" then
    self._timer = self._timer - 1
    if self._timer <= 0 and not self._audio:isMusicFadeActive() then
      self._audio:stopMusic()
      self._audio:playMusic("SEQ_GS_STARTING2")
      self._phase = "oak_reveal_wait"
      self._timer = OAK_REVEAL_WAIT
      self._visual = "oak"
      self:_event("oak_revealed", "oak")
    end
  elseif self._phase == "oak_reveal_wait" or self._phase == "marill_appearance_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      if self._phase == "oak_reveal_wait" then
        self._phase = "marill_appearance_wait"
        self._timer = MARILL_APPEARANCE_WAIT
      else
        self:_startCry()
      end
    end
  elseif self._phase == "marill_cry_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._phase = "profile"
      self._visual = "oak"
      self:_setMessage("profile.ask")
    end
  elseif self._phase == "shrink_wait" then
    self._timer = self._timer - 1
    if self._timer == 0 then
      self._audio:play("SEQ_SE_GS_HERO_SHUKUSHOU")
      self._visual = self._genderFocus == 0 and "shrink.male" or "shrink.female"
      self:_finish()
    end
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
  self._visual = "background"
  self:_event("name_editor", "opened")
end

function OakIntroController:press(action)
  assert(type(action) == "string", "Oak semantic action must be a string")
  if self._disposed or not self._started or self._phase == "complete" then
    return false
  end
  if action == "left" and self._phase == "gender_select" then
    self._genderFocus = 0
    self._audio:play("SEQ_SE_DP_SELECT")
  elseif action == "right" and self._phase == "gender_select" then
    self._genderFocus = 1
    self._audio:play("SEQ_SE_DP_SELECT")
  elseif
    self._phase == "name_edit" and (action == "left" or action == "right" or action == "up" or action == "down")
  then
    local step = (action == "left" or action == "up") and -1 or 1
    self._virtualFocus = ((self._virtualFocus - 1 + step) % #self._virtualGlyphs) + 1
    self._audio:play("SEQ_SE_DP_SELECT")
  elseif action == "grid_confirm" and self._phase == "name_edit" then
    self:inputText(self._virtualGlyphs[self._virtualFocus])
  elseif (action == "confirm" or action == "yes") and self._phase == "greeting" then
    self._audio:fadeMusicOut({ target = 0, durationTicks = MUSIC_FADE_FRAMES })
    self._phase = "fade_wait"
    self._timer = MUSIC_FADE_FRAMES
  elseif (action == "confirm" or action == "yes") and self._phase == "profile" then
    self._phase = "gender_question"
    self:_setMessage("profile.gender_question")
  elseif (action == "confirm" or action == "yes") and self._phase == "gender_question" then
    self._phase = "gender_select"
    self._visual = "gender.indicator"
    self:_setMessage("profile.gender_select")
  elseif (action == "confirm" or action == "yes") and self._phase == "gender_select" then
    self._phase = "gender_confirm"
    self:_setMessage("profile.gender_confirm")
  elseif (action == "cancel" or action == "no") and self._phase == "gender_confirm" then
    self._phase = "gender_question"
    self:_setMessage("profile.gender_question")
  elseif (action == "confirm" or action == "yes") and self._phase == "gender_confirm" then
    self:_enterNameEditor()
  elseif (action == "submit" or action == "confirm" or action == "yes") and self._phase == "name_edit" then
    if #self._name > 0 then
      local glyphs = appendGlyphs(self._name)
      if #glyphs >= 1 and #glyphs <= 7 then
        self._phase = "name_confirm"
        self:_setMessage("profile.name_confirm")
      end
    end
  elseif (action == "cancel" or action == "no") and self._phase == "name_confirm" then
    self._phase = "gender_question"
    self:_setMessage("profile.gender_question")
  elseif (action == "confirm" or action == "yes") and self._phase == "name_confirm" then
    self._phase = "final_dialogue"
    self:_setMessage("profile.final")
  elseif (action == "confirm" or action == "yes") and self._phase == "final_dialogue" then
    self._phase = "shrink_wait"
    self._timer = SHRINK_WAIT
    self:_event("shrink_started", "player")
  else
    return false
  end
  return true
end

---@param text string
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
  return {
    phase = self._phase,
    message = self._message,
    visual = self._visual,
    genderFocus = self._genderFocus,
    name = self._name,
    virtualGlyphFocus = self._virtualFocus,
    nameInputEnabled = self._phase == "name_edit",
    sourceFrames = self._sourceFrames,
    events = self._events,
  }
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
