-- Player profile selection, name editing, and finalization state for Oak intro.

local NewGame = require("game.hgss.src.newgame.NewGame")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")

---@class OakProfileFlowOptions
---@field candidate table<string, unknown>
---@field audio GameSound
---@field playerDataContext { charmap: table<string, integer>, frameIndexes: table<integer, boolean> }
---@field randomU32 fun(): number
---@field virtualGlyphs string[]
---@field virtualKeyColumns integer?

---@class OakProfileFlow
---@field new fun(options: OakProfileFlowOptions): OakProfileFlow
---@field private _candidate table<string, unknown>
---@field private _audio GameSound
---@field private _playerDataContext { charmap: table<string, integer>, frameIndexes: table<integer, boolean> }
---@field private _randomU32 fun(): number
---@field private _virtualGlyphs string[]
---@field private _virtualKeyColumns integer
---@field private _virtualFocus integer
---@field private _genderSelection integer
---@field private _name string
---@field private _confirmationChoice { kind: string, selected: integer }?
---@field private _result table<string, unknown>?
local OakProfileFlow = {}
OakProfileFlow.__index = OakProfileFlow

local DEFAULT_PROFILE_NAMES = { [0] = "Ethan", [1] = "Lyra" }

local function appendGlyphs(text)
  local glyphs = {}
  for glyph in Utf8Glyphs.iter(text) do
    glyphs[#glyphs + 1] = glyph
  end
  return glyphs
end

local function isBlankName(name)
  for glyph in Utf8Glyphs.iter(name) do
    if glyph ~= " " then
      return false
    end
  end
  return true
end

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

function OakProfileFlow.new(options)
  assert(type(options) == "table", "Oak profile flow requires options")
  assert(
    type(options.candidate) == "table" and options.candidate.playerData == nil,
    "Oak intro requires a partial candidate"
  )
  assert(type(options.audio) == "table" and type(options.audio.play) == "function", "Oak profile flow requires audio")
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
    _audio = options.audio,
    _playerDataContext = options.playerDataContext,
    _randomU32 = options.randomU32,
    _virtualGlyphs = options.virtualGlyphs,
    _virtualKeyColumns = math.max(1, math.min(10, options.virtualKeyColumns or 10)),
    _virtualFocus = 1,
    _genderSelection = 0,
    _name = "",
    _confirmationChoice = nil,
    _result = nil,
  }, OakProfileFlow)
end

function OakProfileFlow:_playSelectionEffect()
  self._audio:play("SEQ_SE_DP_SELECT")
end

function OakProfileFlow:_virtualKeys()
  local keys = {}
  for _, glyph in ipairs(self._virtualGlyphs) do
    keys[#keys + 1] = { kind = "glyph", glyph = glyph }
  end
  keys[#keys + 1] = { kind = "delete" }
  keys[#keys + 1] = { kind = "confirm" }
  return keys
end

function OakProfileFlow:gender()
  return self._genderSelection
end

function OakProfileFlow:name()
  return self._name
end

function OakProfileFlow:candidate()
  return self._candidate
end

function OakProfileFlow:result()
  return self._result
end

function OakProfileFlow:confirmationChoice()
  return self._confirmationChoice
      and {
        kind = self._confirmationChoice.kind,
        selected = self._confirmationChoice.selected,
      }
    or nil
end

function OakProfileFlow:beginConfirmation(kind)
  assert(kind == "gender" or kind == "name", "unknown Oak confirmation kind: " .. tostring(kind))
  self._confirmationChoice = { kind = kind, selected = 0 }
end

function OakProfileFlow:selectConfirmation(index)
  assert(self._confirmationChoice ~= nil, "Oak confirmation choice is not active")
  index = assertSelectionIndex(index)
  local changed = self._confirmationChoice.selected ~= index
  self._confirmationChoice.selected = index
  if changed then
    self:_playSelectionEffect()
  end
  return changed
end

function OakProfileFlow:focusGender(index)
  index = assertSelectionIndex(index)
  local changed = self._genderSelection ~= index
  self._genderSelection = index
  if changed then
    self:_playSelectionEffect()
  end
  return changed
end

function OakProfileFlow:activateGender(index)
  index = assertSelectionIndex(index)
  self._genderSelection = index
  self:_playSelectionEffect()
  return true
end

function OakProfileFlow:resolveConfirmation(selected)
  assert(self._confirmationChoice ~= nil, "Oak confirmation choice is not active")
  selected = assertSelectionIndex(selected)
  self:_playSelectionEffect()
  local kind = self._confirmationChoice.kind
  self._confirmationChoice = nil
  if kind == "gender" then
    return selected == 0 and "name_prompt" or "gender_question"
  elseif kind == "name" then
    return selected == 0 and "final_dialogue" or "gender_question"
  end
  error("unknown Oak confirmation kind: " .. tostring(kind), 0)
end

function OakProfileFlow:enterNameEditor()
  self._name = ""
  self._virtualFocus = 1
end

function OakProfileFlow:inputText(text)
  assert(type(text) == "string", "Oak text input must be a string")
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

function OakProfileFlow:deleteGlyph()
  local glyphs = appendGlyphs(self._name)
  glyphs[#glyphs] = nil
  self._name = table.concat(glyphs)
  return true
end

function OakProfileFlow:submitName()
  if #appendGlyphs(self._name) > 7 then
    return false
  end
  if isBlankName(self._name) then
    self._name = assert(DEFAULT_PROFILE_NAMES[self._genderSelection])
  end
  return #appendGlyphs(self._name) >= 1
end

function OakProfileFlow:pressName(action)
  if action == "left" or action == "right" or action == "up" or action == "down" then
    local count = #self._virtualGlyphs + 2
    local columns = self._virtualKeyColumns
    local step = action == "left" and -1 or action == "right" and 1 or action == "up" and -columns or columns
    self._virtualFocus = ((self._virtualFocus - 1 + step) % count) + 1
    self._audio:play("SEQ_SE_DP_SELECT")
    return true
  elseif action == "confirm" then
    local key = self:_virtualKeys()[self._virtualFocus]
    if key.kind == "glyph" then
      return self:inputText(key.glyph)
    elseif key.kind == "delete" then
      return self:deleteGlyph()
    end
    local accepted = self:submitName()
    return accepted, accepted and "submit" or nil
  elseif action == "submit" or action == "yes" then
    local accepted = self:submitName()
    return accepted, accepted and "submit" or nil
  end
  return false
end

function OakProfileFlow:finalize()
  local finalized, failure = NewGame.finalize(self._candidate, {
    name = self._name,
    gender = self._genderSelection,
  }, {
    randomU32 = self._randomU32,
    playerDataContext = self._playerDataContext,
  })
  assert(finalized, failure and failure.message or "Oak profile finalization failed")
  self._result = finalized
  return finalized
end

function OakProfileFlow:inputFocus()
  return self._virtualFocus
end

function OakProfileFlow:snapshot()
  return {
    genderFocus = self._genderSelection,
    name = self._name,
    virtualGlyphFocus = self._virtualFocus,
    virtualKeys = self:_virtualKeys(),
    virtualKeyColumns = self._virtualKeyColumns,
    confirmationChoice = self:confirmationChoice(),
  }
end

return OakProfileFlow
