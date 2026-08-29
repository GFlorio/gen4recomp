-- Top-level Oak/profile presentation state. It maps host callbacks to one
-- semantic controller, owns text-input mode and intro images, and hands one
-- finalized unpublished candidate to its caller.

local OakIntroLayout = require("game.src.game.OakIntroLayout")
local OakIntroRenderer = require("game.src.game.OakIntroRenderer")
local Utf8Glyphs = require("libs.assets.src.Utf8Glyphs")
local DialoguePresentationLayout = require("libs.engine.src.DialoguePresentationLayout")

---@class OakIntroStateController: OakIntroController
---@field start fun(self: OakIntroStateController): boolean
---@field tick fun(self: OakIntroStateController, frames: integer)
---@field view fun(self: OakIntroStateController): OakIntroControllerView
---@field result fun(self: OakIntroStateController): table?
---@field press fun(self: OakIntroStateController, action: string): boolean
---@field deleteGlyph fun(self: OakIntroStateController): boolean
---@field inputText fun(self: OakIntroStateController, text: string): boolean
---@field messageCompleted fun(self: OakIntroStateController, key: string): boolean
---@field dispose fun(self: OakIntroStateController)

---@class OakIntroStateRenderer
---@field draw fun(self: OakIntroStateRenderer, view: OakIntroStateView)
---@field dispose fun(self: OakIntroStateRenderer)

---@class OakIntroStateTextInputHost
---@field setTextInput fun(self: OakIntroStateTextInputHost, enabled: boolean)

---@class OakIntroStateAudioSink
---@field update? fun(self: OakIntroStateAudioSink)

---@class OakIntroStateRectangle
---@field x number
---@field y number
---@field width number
---@field height number

---@class OakIntroStateSubjectRectangle: OakIntroStateRectangle
---@field scale number

---@class OakIntroStateLayout
---@field viewport OakIntroStateRectangle
---@field message OakIntroStateRectangle
---@field cards table<integer, OakIntroStateRectangle>
---@field nameGrid table<integer, { rect: OakIntroStateRectangle, kind: string, glyph: string? }>
---@field nameKeys table<integer, { rect: OakIntroStateRectangle, kind: string, glyph: string?, label: string? }>
---@field namePreview OakIntroStateRectangle?
---@field stageContent OakIntroStateRectangle
---@field dialogue { outerRect: OakIntroStateRectangle, scale: number }?
---@field sourceCanvas { scale: number, origin: { x: number, y: number } }?
---@field revealCanvas { scale: number, origin: { x: number, y: number } }?
---@field reveal OakIntroStateSubjectRectangle?
---@field stage OakIntroStateRectangle
---@field profileCards table<integer, OakIntroStateRectangle>
---@field choicePanel OakIntroStateRectangle?
---@field choiceRows table<integer, OakIntroStateRectangle>?
---@field virtualKeyColumns integer?
---@field genderFocus integer
---@field subject OakIntroStateSubjectRectangle?
---@field safeFrame OakIntroStateRectangle
---@field scene OakIntroStateRectangle
---@field oakRegion OakIntroStateRectangle?
---@field selectorRegion OakIntroStateRectangle?
---@field selectorPanel OakIntroStateRectangle?
---@field genderBackground OakIntroStateSubjectRectangle?
---@field genderChoices table<integer, OakIntroStateSubjectRectangle>
---@field genderHitRegions table<integer, OakIntroStateRectangle>?
---@field genderCanvas { scale: number, origin: { x: number, y: number } }?

---@class OakIntroStateView: OakIntroControllerView
---@field phase string
---@field message string|table|nil
---@field messageKey string?
---@field dialogueStatus table?
---@field dialoguePresentation DialoguePresentationLayout.Presentation?
---@field dialogue table?
---@field visual string
---@field genderFocus integer
---@field name string
---@field nameInputEnabled boolean
---@field choiceLabels table<integer, string>?
---@field layout OakIntroStateLayout?

---@class OakIntroStateLayoutView: OakIntroStateView
---@field layout OakIntroStateLayout

---@class OakIntroStateOptions
---@field controller OakIntroController
---@field manifest table
---@field renderer OakIntroStateRenderer?
---@field graphics any?
---@field imageLoader (fun(path: string): any)?
---@field textInputHost OakIntroStateTextInputHost?
---@field glyphs string[]?
---@field width number?
---@field height number?
---@field onComplete fun(result: table)?
---@field audioSink OakIntroStateAudioSink?
---@field audioLifetime table?
---@field textRenderer table
---@field dialogueController table?
---@field dialogueRenderer table?
---@field dialogueText table?
---@field dialogueMessages table?
---@field dialogueFormatter table?
---@field dialogueMessageKey string?
---@field dialogueCursorPlacement { x: number, y: number, width: number, height: number }?

---@class OakIntroState
---@field new fun(options: OakIntroStateOptions): OakIntroState
---@field controller OakIntroStateController
---@field renderer OakIntroStateRenderer
---@field inputHost OakIntroStateTextInputHost
---@field glyphs string[]
---@field width number
---@field height number
---@field accumulator number
---@field textInputEnabled boolean?
---@field completed boolean
---@field onComplete fun(result: table)?
---@field audioSink OakIntroStateAudioSink?
---@field audioLifetime table?
---@field manifest table
---@field dialogueController table?
---@field dialogueRenderer table?
---@field dialogueMessages table?
---@field dialogueFormatter table?
---@field choiceLabels table<integer, string>?
---@field dialogueText table?
---@field dialoguePresentation DialoguePresentationLayout.Presentation?
---@field dialogueCursorPlacement { x: number, y: number, width: number, height: number }?
---@field disposed boolean
---@field shrinkCursor string? identity of the newest full-art/shrink image `update` has queued or a real `draw` has presented live
---@field shrinkBacklog OakIntroStateLayoutView[] full-art/shrink views queued by `update`, oldest first, awaiting a real `draw`
---@field _setTextInput fun(self: OakIntroState, enabled: boolean)
---@field _shrinkKey fun(self: OakIntroState, view: OakIntroControllerView): string?
---@field _sync fun(self: OakIntroState): OakIntroStateView
---@field update fun(self: OakIntroState, dt: number)
---@field tick fun(self: OakIntroState, frames: integer)
---@field view fun(self: OakIntroState): OakIntroStateLayoutView
---@field draw fun(self: OakIntroState)
---@field resize fun(self: OakIntroState, width: number, height: number)
---@field keypressed fun(self: OakIntroState, key: string, scancode: string?, isrepeat: boolean?)
---@field press fun(self: OakIntroState, action: string): boolean
---@field textinput fun(self: OakIntroState, text: string)
---@field gamepadpressed fun(self: OakIntroState, joystick: any, button: string)
---@field _pointer fun(self: OakIntroState, x: number, y: number)
---@field mousepressed fun(self: OakIntroState, x: number, y: number, button: integer)
---@field touchpressed fun(self: OakIntroState, id: any, x: number, y: number)
---@field dispose fun(self: OakIntroState)
local OakIntroState = {}
OakIntroState.__index = OakIntroState

local DEFAULT_GLYPHS = {
  "A",
  "B",
  "C",
  "D",
  "E",
  "F",
  "G",
  "H",
  "I",
  "J",
  "K",
  "L",
  "M",
  "N",
  "O",
  "P",
  "Q",
  "R",
  "S",
  "T",
  "U",
  "V",
  "W",
  "X",
  "Y",
  "Z",
}

local function glyphList(value)
  local result = {}
  for _, glyph in ipairs(value or DEFAULT_GLYPHS) do
    assert(type(glyph) == "string", "Oak virtual keyboard glyphs must be strings")
    local count = 0
    for _ in Utf8Glyphs.iter(glyph) do
      count = count + 1
    end
    assert(count == 1, "Oak virtual keyboard entries must be one UTF-8 glyph")
    result[#result + 1] = glyph
  end
  return result
end

local function textInputHost(host)
  if host ~= nil then
    assert(type(host.setTextInput) == "function", "Oak text-input host must provide setTextInput")
    return host
  end
  return {
    setTextInput = function(_, enabled)
      love.keyboard.setTextInput(enabled)
    end,
  }
end

---@param options OakIntroStateOptions
---@return OakIntroState
function OakIntroState.new(options)
  assert(type(options) == "table" and options.controller, "Oak state requires a controller")
  assert(type(options.manifest) == "table", "Oak state requires generated intro assets")
  if options.dialogueController then
    assert(options.dialogueFormatter, "Oak state requires its message formatter")
    assert(type(options.dialogueFormatter.format) == "function", "Oak message formatter is invalid")
  end
  local width, height = options.width, options.height
  if width == nil or height == nil then
    width, height = love.graphics.getDimensions()
  end
  local self
  local ok, result = pcall(function()
    local renderer = options.renderer
      or OakIntroRenderer.new({
        manifest = options.manifest,
        graphics = options.graphics,
        imageLoader = options.imageLoader,
        text = assert(options.textRenderer, "Oak state requires the shared FieldTextRenderer"),
      })
    self = setmetatable({
      controller = options.controller,
      manifest = options.manifest,
      renderer = renderer --[[@as OakIntroStateRenderer]],
      inputHost = textInputHost(options.textInputHost),
      glyphs = glyphList(options.glyphs),
      width = width,
      height = height,
      accumulator = 0,
      textInputEnabled = nil,
      shrinkCursor = nil,
      shrinkBacklog = {},
      completed = false,
      disposed = false,
      onComplete = options.onComplete,
      audioSink = options.audioSink,
      audioLifetime = options.audioLifetime,
      dialogueController = options.dialogueController,
      dialogueRenderer = options.dialogueRenderer,
      dialogueFormatter = options.dialogueFormatter,
      choiceLabels = options.dialogueFormatter and options.dialogueFormatter:choiceLabels() or nil,
      dialogueText = options.dialogueText,
      dialoguePresentation = nil,
      dialogueMessageKey = nil,
      dialogueCursorPlacement = options.dialogueCursorPlacement,
    }, OakIntroState)
    self:_setTextInput(false)
    self.controller:start()
    return self
  end)
  if not ok then
    if options.controller.dispose then
      pcall(options.controller.dispose, options.controller)
    end
    if self and self.renderer and self.renderer.dispose then
      pcall(self.renderer.dispose, self.renderer)
    end
    if self and self.audioLifetime then
      pcall(self.audioLifetime.dispose, self.audioLifetime)
    end
    error(result, 0)
  end
  return self
end

function OakIntroState:_setTextInput(enabled)
  if self.textInputEnabled == enabled then
    return
  end
  self.inputHost:setTextInput(enabled)
  self.textInputEnabled = enabled
end

function OakIntroState:_sync()
  local view = self.controller:view()
  ---@cast view OakIntroStateView
  self:_setTextInput(view.nameInputEnabled)
  if self.dialogueController and view.messageKey ~= self.dialogueMessageKey then
    self.dialogueMessageKey = view.messageKey
    if view.messageKey then
      local message = self.dialogueFormatter:format(view.messageKey, { playerName = view.name })
      assert(not message.hadUnresolvedSubstitutions, "Oak message has unresolved substitutions")
      local handle = self.dialogueController:open({
        id = "oak:" .. view.messageKey,
        message = message,
        frameIndex = 0,
        allowCancel = false,
      })
      handle:onComplete(function()
        self.controller:messageCompleted(view.messageKey)
      end)
    end
  end
  if view.phase == "complete" and not self.completed then
    self.completed = true
    if self.onComplete then
      self.onComplete(assert(self.controller:result()))
    end
  end
  return view
end

-- The profile shrink sequence holds one full-art image for a fixed source
-- duration and then steps through the generated replacement frames one at a
-- time. `_shrinkKey` identifies which of those distinct images is currently
-- selected (nil outside the sequence), so `update` can tell when it has just
-- crossed into a different one and queue it in `shrinkBacklog` for a real
-- `draw` to present later, without ever waiting for that `draw` itself.
function OakIntroState:_shrinkKey(view)
  if view.phase == "final_full_art_hold" then
    return "hold"
  end
  if view.phase == "shrink_animation" then
    return view.visual .. "#" .. view.visualFrameIndex
  end
  return nil
end

function OakIntroState:update(dt)
  assert(type(dt) == "number" and dt >= 0, "Oak update dt must be non-negative")
  self.accumulator = self.accumulator + dt
  while self.accumulator >= 1 / 60 do
    self.accumulator = self.accumulator - 1 / 60
    local phaseBeforeDialogue = self.controller:view().phase
    if self.dialogueController then
      self.dialogueController:step()
    end
    local phaseAfterDialogue = self.controller:view().phase
    local genderCompositionStarted = phaseBeforeDialogue == "gender_question"
      and phaseAfterDialogue == "gender_composition_transition"
    if not genderCompositionStarted then
      self.controller:tick(1)
    end
    local currentShrinkKey = self:_shrinkKey(self.controller:view())
    if currentShrinkKey ~= nil and currentShrinkKey ~= self.shrinkCursor then
      -- A distinct full-art/shrink image just became current. Snapshot the
      -- decorated view now (before any later resize can change its
      -- geometry) and queue it for a real `draw` to present, then stop
      -- draining this host's catch-up budget for this call: a badly-lagging
      -- host that keeps calling `update`/`draw` every host frame gets
      -- exactly one freshly queued image per call, so a real `draw` always
      -- gets a turn to drain the backlog before the next image is queued.
      -- This never blocks a host that skips `draw` entirely -- its next
      -- `update` call simply keeps advancing from here.
      self.shrinkCursor = currentShrinkKey
      table.insert(self.shrinkBacklog, self:view())
      break
    end
    if self.controller:view().phase == "complete" then
      break
    end
  end
  if self.audioSink and self.audioSink.update then
    self.audioSink:update()
  end
  self:_sync()
end

function OakIntroState:tick(frames)
  assert(frames >= 0 and frames % 1 == 0, "Oak tick count must be a non-negative integer")
  for _ = 1, frames do
    local phaseBeforeDialogue = self.controller:view().phase
    if self.dialogueController then
      self.dialogueController:step()
    end
    local phaseAfterDialogue = self.controller:view().phase
    local genderCompositionStarted = phaseBeforeDialogue == "gender_question"
      and phaseAfterDialogue == "gender_composition_transition"
    if not genderCompositionStarted then
      self.controller:tick(1)
    end
  end
  self:_sync()
end

function OakIntroState:view()
  local view = self.controller:view()
  ---@cast view OakIntroStateView
  view.layout = OakIntroLayout.compute(self.width, self.height, view, self.glyphs, self.manifest)
  if self.dialogueController then
    view.dialogueStatus = self.dialogueController:status()
    view.dialoguePresentation = view.layout.dialogue
        and DialoguePresentationLayout.compute(view.layout.dialogue.outerRect, {
          scale = view.layout.dialogue.scale,
          cursorPlacement = self.dialogueCursorPlacement,
        })
      or nil
  end
  view.choiceLabels = self.choiceLabels
  ---@cast view OakIntroStateLayoutView
  return view
end

function OakIntroState:draw()
  local view = table.remove(self.shrinkBacklog, 1)
  if view == nil then
    view = self:view()
    -- Nothing was queued (a fresh view, or one reached via the frame-counted
    -- `tick` test helper, which never queues): this live view is this
    -- image's real presentation, so it must not be queued again later.
    local liveShrinkKey = self:_shrinkKey(view)
    if liveShrinkKey ~= nil then
      self.shrinkCursor = liveShrinkKey
    end
  end
  self.renderer:draw(view)
  if self.dialogueController and self.dialogueRenderer then
    self.dialogueRenderer:draw(self.dialogueController, view.dialoguePresentation)
  end
end

function OakIntroState:resize(width, height)
  assert(type(width) == "number" and type(height) == "number", "Oak resize needs dimensions")
  self.width, self.height = width, height
end

local CONFIRM_KEYS = { ["return"] = true, kpenter = true, space = true }

---@param key string
---@param isrepeat boolean?
function OakIntroState:keypressed(key, _, isrepeat)
  if isrepeat and CONFIRM_KEYS[key] then
    return
  end
  if key == "left" or key == "right" or key == "up" or key == "down" or CONFIRM_KEYS[key] or key == "escape" then
    local action = key == "escape" and "cancel"
      or ({ ["left"] = "left", ["right"] = "right", ["up"] = "up", ["down"] = "down" })[key]
      or "confirm"
    if self.dialogueController and self.dialogueController:isModal() then
      self.dialogueController:step({ actionPressed = action == "confirm", cancelPressed = action == "cancel" })
      self:_sync()
      return
    end
    self.controller:press(action)
  elseif key == "backspace" then
    self.controller:deleteGlyph()
  end
  self:_sync()
end

function OakIntroState:textinput(text)
  self.controller:inputText(text)
  self:_sync()
end

function OakIntroState:gamepadpressed(_, button)
  local action = ({ dpup = "up", dpdown = "down", dpleft = "left", dpright = "right", a = "confirm", b = "cancel" })[button]
  if
    action == "left"
    or action == "right"
    or action == "up"
    or action == "down"
    or action == "confirm"
    or action == "cancel"
  then
    if self.dialogueController and self.dialogueController:isModal() then
      self.dialogueController:step({ actionPressed = action == "confirm", cancelPressed = action == "cancel" })
      self:_sync()
      return
    end
    self.controller:press(action)
  end
  self:_sync()
end

function OakIntroState:_pointer(x, y)
  local view = self:view()
  local layout = view.layout
  if view.confirmationChoice then
    for selected = 0, 1 do
      if OakIntroLayout.contains(layout.choiceRows[selected], x, y) then
        self.controller:press(selected == 0 and "yes" or "no")
        self:_sync()
        return
      end
    end
  elseif view.phase == "gender_select" then
    for gender = 0, 1 do
      if OakIntroLayout.contains(layout.genderHitRegions[gender], x, y) then
        self.controller:press(gender == 0 and "left" or "right")
        self.controller:press("confirm")
        return
      end
    end
  elseif view.phase == "name_edit" then
    for _, entry in pairs(layout.nameKeys or layout.nameGrid) do
      if OakIntroLayout.contains(entry.rect, x, y) then
        if entry.kind == "glyph" then
          self.controller:inputText(assert(entry.glyph))
        elseif entry.kind == "delete" then
          self.controller:deleteGlyph()
        elseif entry.kind == "confirm" then
          self.controller:press("submit")
        end
        return
      end
    end
  end
  self:_sync()
end

function OakIntroState:mousepressed(x, y, button)
  if button == 1 then
    self:_pointer(x, y)
  end
end

function OakIntroState:touchpressed(_, x, y)
  self:_pointer(x, y)
end

function OakIntroState:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  self:_setTextInput(false)
  self.controller:dispose()
  if self.renderer then
    self.renderer:dispose()
    self.renderer = nil
  end
  if self.audioLifetime then
    self.audioLifetime:dispose()
    self.audioLifetime = nil
  end
  if self.dialogueRenderer and self.dialogueRenderer.release then
    self.dialogueRenderer:release()
  end
  if self.dialogueText and self.dialogueText.release then
    self.dialogueText:release()
  end
  if self.dialogueController and self.dialogueController.dispose then
    self.dialogueController:dispose()
  end
end

return OakIntroState
