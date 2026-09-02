-- Pure host-native geometry for the Oak intro. Source dimensions are semantic
-- placement relationships, never a fixed render surface.

local ImageButton = require("libs.ui.src.ImageButton")
local TextButton = require("libs.ui.src.TextButton")

local OakIntroLayout = {}

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function rect(x, y, width, height)
  assert(width > 0 and height > 0, "Oak layout rectangle must be positive")
  return { x = x, y = y, width = width, height = height }
end

local function widget(manifest, id)
  local value = assert(manifest.widgets[id], "Oak widget metrics are missing: " .. id)
  assert(value.width > 0 and value.height > 0 and value.anchor, "Oak widget metrics are invalid")
  assert(value.sourceBounds, "Oak widget source bounds are missing: " .. id)
  return value
end

---@param region { x: number, y: number, width: number, height: number }
---@param reference { width: number, height: number }
---@return { scale: number, origin: { x: number, y: number }, [string]: unknown }
local function canvasForRegion(region, reference)
  local scale = math.min(region.width / reference.width, region.height / reference.height)
  local origin = {
    x = region.x + (region.width - reference.width * scale) / 2,
    y = region.y + (region.height - reference.height * scale) / 2,
  }
  assert(scale > 0, "source-canvas scale must be positive")
  return { scale = scale, origin = origin }
end

---@param scene { x: number, y: number, width: number, height: number }
---@param reference { width: number, height: number }
---@return { scale: number, origin: { x: number, y: number }, scene: table, reference: table }
local function sourceCanvas(scene, reference)
  local canvas = canvasForRegion(scene, reference)
  canvas.scene = scene
  canvas.reference = reference
  return canvas
end

---@param canvas { scale: number, origin: { x: number, y: number } }
---@param sourcePointValue { x: number, y: number }
---@return { x: number, y: number }
local function canvasPoint(canvas, sourcePointValue)
  return {
    x = canvas.origin.x + sourcePointValue.x * canvas.scale,
    y = canvas.origin.y + sourcePointValue.y * canvas.scale,
  }
end

-- Maps a widget's own anchor point (plus an optional source-space
-- displacement) through the shared canvas. A widget's rendered pixel
-- dimensions equal its sourceBounds dimensions, so scaling by canvas.scale
-- alone reproduces its source size; this is the single mapper for any
-- source-positioned, anchor-addressed widget (Oak's slide included).
local function sourceWidgetRect(widgetValue, canvas, displaceX, displaceY)
  local anchorSource = {
    x = widgetValue.sourceBounds.x + widgetValue.anchor.x + (displaceX or 0),
    y = widgetValue.sourceBounds.y + widgetValue.anchor.y + (displaceY or 0),
  }
  local hostAnchor = canvasPoint(canvas, anchorSource)
  return {
    x = hostAnchor.x - widgetValue.anchor.x * canvas.scale,
    y = hostAnchor.y - widgetValue.anchor.y * canvas.scale,
    width = widgetValue.width * canvas.scale,
    height = widgetValue.height * canvas.scale,
    scale = canvas.scale,
  }
end

local function revealRect(revealWidget, canvas)
  assert(revealWidget.sourceCenter, "Oak reveal source center is missing")
  local hostCenter = canvasPoint(canvas, revealWidget.sourceCenter)
  return {
    x = hostCenter.x - revealWidget.anchor.x * canvas.scale,
    y = hostCenter.y - revealWidget.anchor.y * canvas.scale,
    width = revealWidget.width * canvas.scale,
    height = revealWidget.height * canvas.scale,
    scale = canvas.scale,
  }
end

local function composedOakRect(startRect, oak, oakRegion, progress)
  local targetScale = math.min(startRect.scale, oakRegion.width / oak.width, oakRegion.height / oak.height)
  local targetWidth, targetHeight = oak.width * targetScale, oak.height * targetScale
  local targetX = oakRegion.x + (oakRegion.width - targetWidth) / 2
  local targetY = oakRegion.y + (oakRegion.height - targetHeight) / 2
  local scale = startRect.scale + (targetScale - startRect.scale) * progress
  return {
    x = startRect.x + (targetX - startRect.x) * progress,
    y = startRect.y + (targetY - startRect.y) * progress,
    width = oak.width * scale,
    height = oak.height * scale,
    scale = scale,
  }
end

local function interpolateSubjectRect(from, to, progress)
  assert(
    type(progress) == "number"
      and progress == progress
      and progress > -math.huge
      and progress < math.huge
      and progress >= 0
      and progress <= 1,
    "Oak subject interpolation progress is invalid"
  )
  assert(from.scale > 0 and to.scale > 0, "Oak subject interpolation scale is invalid")
  local scale = from.scale + (to.scale - from.scale) * progress
  return {
    x = from.x + (to.x - from.x) * progress,
    y = from.y + (to.y - from.y) * progress,
    width = from.width + (to.width - from.width) * progress,
    height = from.height + (to.height - from.height) * progress,
    scale = scale,
  }
end

local function selectorRegions(safeFrame, gap)
  gap = math.min(gap, math.min(safeFrame.width, safeFrame.height) / 2)
  if safeFrame.width >= safeFrame.height * 1.15 then
    local oakWidth = (safeFrame.width - gap) * 0.46
    return rect(safeFrame.x, safeFrame.y, oakWidth, safeFrame.height),
      rect(safeFrame.x + oakWidth + gap, safeFrame.y, safeFrame.width - oakWidth - gap, safeFrame.height)
  end
  local oakHeight = (safeFrame.height - gap) * 0.42
  return rect(safeFrame.x, safeFrame.y, safeFrame.width, oakHeight),
    rect(safeFrame.x, safeFrame.y + oakHeight + gap, safeFrame.width, safeFrame.height - oakHeight - gap)
end

---@param canvas { scale: number, origin: { x: number, y: number } }
---@param source { x: number, y: number, width: number, height: number }
---@return { x: number, y: number, width: number, height: number }
local function mappedRect(canvas, source)
  return {
    x = canvas.origin.x + source.x * canvas.scale,
    y = canvas.origin.y + source.y * canvas.scale,
    width = source.width * canvas.scale,
    height = source.height * canvas.scale,
  }
end

---@param widgetValue table
---@param canvas { scale: number, origin: { x: number, y: number } }
---@return { x: number, y: number, width: number, height: number, scale: number }
local function sourceCenteredWidget(widgetValue, canvas)
  local center = assert(widgetValue.sourceCenter, "Oak selector source center is missing")
  local hostCenter = canvasPoint(canvas, center)
  return {
    x = hostCenter.x - widgetValue.anchor.x * canvas.scale,
    y = hostCenter.y - widgetValue.anchor.y * canvas.scale,
    width = widgetValue.width * canvas.scale,
    height = widgetValue.height * canvas.scale,
    scale = canvas.scale,
  }
end

local function confirmationScale(selectorRegion, cardSource)
  local cardWidth, cardHeight = cardSource.width, cardSource.height
  local stackWidth = TextButton.REFERENCE_WIDTH
  local stackHeight = TextButton.REFERENCE_HEIGHT * 2 + 8
  local groupWidth, groupHeight = cardWidth + 8 + stackWidth, math.max(cardHeight, stackHeight)
  local sourceScale = math.min(selectorRegion.width / 256, selectorRegion.height / 192)
  local availableWidth = selectorRegion.width >= 24 and selectorRegion.width - 24 or selectorRegion.width
  local availableHeight = selectorRegion.height >= 24 and selectorRegion.height - 24 or selectorRegion.height
  local insetScale = math.min(availableWidth / groupWidth, availableHeight / groupHeight)
  local scale = math.min(sourceScale, insetScale)
  assert(scale > 0, "Oak gender confirmation scale must be positive")
  return scale
end

local function textButtonEntries(origin, scale, horizontal, gap)
  local refW, refH = TextButton.REFERENCE_WIDTH, TextButton.REFERENCE_HEIGHT
  local w, h = refW * scale, refH * scale
  local entries = {}
  if horizontal then
    local firstRect = rect(origin.x, origin.y, w, h)
    local secondRect = rect(origin.x + w + gap, origin.y, w, h)
    entries[0] =
      { key = "yes", rect = firstRect, scale = scale, button = TextButton.resolve({ rect = firstRect, scale = scale }) }
    entries[1] = {
      key = "no",
      rect = secondRect,
      scale = scale,
      button = TextButton.resolve({ rect = secondRect, scale = scale }),
    }
  else
    local firstRect = rect(origin.x, origin.y, w, h)
    local secondRect = rect(origin.x, origin.y + h + gap, w, h)
    entries[0] =
      { key = "yes", rect = firstRect, scale = scale, button = TextButton.resolve({ rect = firstRect, scale = scale }) }
    entries[1] = {
      key = "no",
      rect = secondRect,
      scale = scale,
      button = TextButton.resolve({ rect = secondRect, scale = scale }),
    }
  end
  return entries
end

local function genderConfirmationEntries(selectorRegion, cardSource, genderWidget, manifest)
  local scale = confirmationScale(selectorRegion, cardSource)
  local cardWidth, cardHeight = cardSource.width, cardSource.height
  local stackWidth = TextButton.REFERENCE_WIDTH
  local stackHeight = TextButton.REFERENCE_HEIGHT * 2 + 8
  local groupWidth, groupHeight = cardWidth + 8 + stackWidth, math.max(cardHeight, stackHeight)
  local origin = {
    x = selectorRegion.x + (selectorRegion.width - groupWidth * scale) / 2,
    y = selectorRegion.y + (selectorRegion.height - groupHeight * scale) / 2,
  }
  local cardLeft = genderWidget == "male" and origin.x or origin.x + (stackWidth + 8) * scale
  local stackLeft = genderWidget == "male" and origin.x + (cardWidth + 8) * scale or origin.x
  local cardTop = origin.y + (groupHeight - cardHeight) * scale / 2
  local stackTop = origin.y + (groupHeight - stackHeight) * scale / 2
  local center =
    assert(genderWidget == "male" and manifest.widgets.gender_male or manifest.widgets.gender_female).sourceCenter
  local relativeCenter = {
    x = center.x - cardSource.x,
    y = center.y - cardSource.y,
  }
  local portrait = {
    x = cardLeft + relativeCenter.x * scale - assert(
      genderWidget == "male" and manifest.widgets.gender_male or manifest.widgets.gender_female
    ).anchor.x * scale,
    y = cardTop + relativeCenter.y * scale - assert(
      genderWidget == "male" and manifest.widgets.gender_male or manifest.widgets.gender_female
    ).anchor.y * scale,
    width = assert(genderWidget == "male" and manifest.widgets.gender_male or manifest.widgets.gender_female).width
      * scale,
    height = assert(genderWidget == "male" and manifest.widgets.gender_male or manifest.widgets.gender_female).height
      * scale,
    scale = scale,
  }
  local cardRect = rect(cardLeft, cardTop, cardWidth * scale, cardHeight * scale)
  local cardButton = ImageButton.resolve({ rect = cardRect, scale = scale })
  local entries = textButtonEntries({ x = stackLeft, y = stackTop }, scale, false, 8 * scale)
  return {
    card = {
      key = genderWidget,
      rect = cardRect,
      scale = scale,
      portraitId = "gender_" .. genderWidget,
      portraitRect = portrait,
      button = cardButton,
    },
    confirmation = entries,
  }
end

local function nameConfirmationEntries(nameStage, choiceRegion)
  local stackSourceHeight = TextButton.REFERENCE_HEIGHT * 2 + 8
  local stageScale = math.min(nameStage.width / 256, nameStage.height / 192)
  local scale =
    math.min(stageScale, choiceRegion.width / TextButton.REFERENCE_WIDTH, choiceRegion.height / stackSourceHeight)
  assert(
    scale == scale and scale > 0 and scale < math.huge and scale > -math.huge,
    "Oak name confirmation scale must be a finite positive number"
  )
  local scaledWidth = TextButton.REFERENCE_WIDTH * scale
  local scaledHeight = stackSourceHeight * scale
  local origin = {
    x = choiceRegion.x + (choiceRegion.width - scaledWidth) / 2,
    y = choiceRegion.y + (choiceRegion.height - scaledHeight) / 2,
  }
  return textButtonEntries(origin, scale, false, 8 * scale)
end

local function nameStageAndRegions(sceneContent, dialogue, gap)
  local nameStage =
    rect(sceneContent.x, sceneContent.y, sceneContent.width, dialogue.outerRect.y - gap - sceneContent.y)
  local oakWidth = (nameStage.width - gap) * 0.46
  local choiceWidth = nameStage.width - oakWidth - gap
  local oakRegion = rect(nameStage.x, nameStage.y, oakWidth, nameStage.height)
  local choiceRegion = rect(nameStage.x + oakWidth + gap, nameStage.y, choiceWidth, nameStage.height)
  return nameStage, oakRegion, choiceRegion
end

---@param width number
---@param height number
---@param view table
---@param glyphs string[]
---@param manifest table
---@return OakIntroStateLayout
function OakIntroLayout.compute(width, height, view, glyphs, manifest)
  assert(type(width) == "number" and width == width and width > 0, "Oak viewport width is invalid")
  assert(type(height) == "number" and height == height and height > 0, "Oak viewport height is invalid")
  assert(type(view) == "table" and type(glyphs) == "table", "Oak layout requires view and glyphs")
  assert(
    type(manifest) == "table" and type(manifest.sourceReference) == "table",
    "Oak layout requires source reference"
  )
  local reference = manifest.sourceReference
  assert(reference.width > 0 and reference.height > 0, "Oak source reference is invalid")
  local minimum = math.min(width, height)
  local inset = math.min(12, math.floor(minimum * 0.035 + 0.5), math.max(0, math.floor((minimum - 1) / 2)))
  local safeFrame = rect(inset, inset, width - inset * 2, height - inset * 2)
  local gap = math.min(8, math.max(0, math.floor(minimum * 0.02 + 0.5)))
  local reservesDialogue = view.dialogue ~= nil
    or view.phase == "name_confirm"
    or view.phase == "name_composition_transition"
    or view.phase == "name_composition_return"
    or view.phase == "final_dialogue"
    or (view.phase == "gender_question" and view.nameCompositionProgress ~= nil and view.nameCompositionProgress > 0)
    or view.phase == "greeting"
    or view.phase == "oak_welcome"
    or view.phase == "oak_world_inhabited"
    or view.phase == "oak_live_alongside"
    or view.phase == "oak_tell_about_yourself"
  local dialogue
  if reservesDialogue then
    local scale = math.min(safeFrame.width / 256, safeFrame.height * 0.28 / 48, 5)
    local outerWidth, outerHeight = 256 * scale, 48 * scale
    dialogue = {
      outerRect = rect(
        safeFrame.x + (safeFrame.width - outerWidth) / 2,
        safeFrame.y + safeFrame.height - outerHeight,
        outerWidth,
        outerHeight
      ),
      scale = scale,
    }
  end
  local scene = rect(0, safeFrame.y, width, safeFrame.height)
  local contentWidth = math.min(scene.width, 1120)
  local sceneContent = rect(scene.x + (scene.width - contentWidth) / 2, scene.y, contentWidth, scene.height)
  local result ---@type OakIntroStateLayout
  result = {
    viewport = rect(0, 0, width, height),
    safeFrame = safeFrame,
    scene = scene,
    stage = scene,
    stageContent = sceneContent,
    dialogue = dialogue,
    message = dialogue and dialogue.outerRect or scene,
    nameGrid = {},
    nameKeys = {},
    genderFocus = view.genderFocus,
  }
  local subjectId = view.primaryWidget
  if subjectId == nil and view.visual ~= "background" then
    subjectId = view.visual
  end
  local canvas = sourceCanvas(scene, reference)
  result.sourceCanvas = canvas
  local subjectWidget
  if subjectId ~= nil then
    subjectWidget = widget(manifest, subjectId)
    local visibleSourceX = subjectId == "oak" and -(view.oakBgScrollX or 0) or 0
    result.subject = sourceWidgetRect(subjectWidget, canvas, visibleSourceX)
  end
  local startSubject = result.subject
  local selectorActive = view.phase == "gender_select" or view.phase == "gender_confirm"
  local compositionProgress = view.genderCompositionProgress
  local nameProgress = view.nameCompositionProgress
  if nameProgress ~= nil then
    assert(
      type(nameProgress) == "number"
        and nameProgress == nameProgress
        and nameProgress > -math.huge
        and nameProgress < math.huge
        and nameProgress >= 0
        and nameProgress <= 1,
      "Oak name composition progress is invalid"
    )
  end
  local oakRegion, selectorRegion
  local compositionActive = selectorActive
    or view.phase == "gender_composition_transition"
    or compositionProgress ~= nil and compositionProgress > 0
  if compositionActive then
    assert(
      type(compositionProgress) == "number"
        and compositionProgress == compositionProgress
        and compositionProgress > -math.huge
        and compositionProgress < math.huge
        and compositionProgress >= 0
        and compositionProgress <= 1,
      "Oak gender composition progress is invalid"
    )
  end
  local genderOakRect
  if compositionActive then
    oakRegion, selectorRegion = selectorRegions(scene, gap)
    result.oakRegion, result.selectorRegion = oakRegion, selectorRegion
    if subjectId == "oak" and startSubject and subjectWidget then
      genderOakRect = composedOakRect(startSubject, subjectWidget, oakRegion, 1)
      result.subject = composedOakRect(startSubject, subjectWidget, oakRegion, compositionProgress)
    end
  end
  local nameStage, nameOakRegion, nameChoiceRegion
  local isNameTransition = view.phase == "name_composition_transition" or view.phase == "name_composition_return"
  local isStaticName = view.phase == "name_confirm"
    or (view.phase == "final_dialogue" and nameProgress ~= nil and nameProgress == 1)
    or (view.phase == "gender_question" and nameProgress ~= nil and nameProgress > 0)
  if (isNameTransition or isStaticName) and startSubject and subjectWidget and subjectId == "oak" then
    assert(dialogue, "Oak name composition requires reserved dialogue")
    nameStage, nameOakRegion, nameChoiceRegion = nameStageAndRegions(sceneContent, assert(dialogue), gap)
    local nameOakRect = composedOakRect(startSubject, subjectWidget, nameOakRegion, 1)
    if view.phase == "name_composition_transition" then
      assert(genderOakRect, "forward transition requires gender endpoint")
      assert(nameProgress ~= nil)
      result.oakRegion, result.selectorRegion = nameOakRegion, nameChoiceRegion
      result.subject = interpolateSubjectRect(genderOakRect, nameOakRect, nameProgress)
    elseif view.phase == "name_composition_return" then
      assert(genderOakRect, "return transition requires gender endpoint")
      assert(nameProgress ~= nil)
      result.oakRegion, result.selectorRegion = nameOakRegion, nameChoiceRegion
      result.subject = interpolateSubjectRect(nameOakRect, genderOakRect, 1 - nameProgress)
    elseif isStaticName then
      result.oakRegion, result.selectorRegion = nameOakRegion, nameChoiceRegion
      result.subject = nameOakRect
    end
  elseif isNameTransition or isStaticName then
    assert(dialogue, "Oak name composition requires reserved dialogue")
    nameStage, nameOakRegion, nameChoiceRegion = nameStageAndRegions(sceneContent, assert(dialogue), gap)
    result.oakRegion, result.selectorRegion = nameOakRegion, nameChoiceRegion
  end
  if view.revealWidget then
    local revealWidget = widget(manifest, view.revealWidget)
    result.revealCanvas = canvas
    result.reveal = revealRect(revealWidget, canvas)
  end
  if selectorActive then
    local selectorCanvas = canvasForRegion(assert(selectorRegion), reference)
    local genderSlots = {}
    for index, sourceGender in ipairs({ "male", "female" }) do
      local sourceCard = assert(manifest.genderSelector.buttons[sourceGender]).bounds
      local card = mappedRect(selectorCanvas, sourceCard)
      local portrait = sourceCenteredWidget(widget(manifest, "gender_" .. sourceGender), selectorCanvas)
      local cardRect = rect(card.x, card.y, card.width, card.height)
      local button = ImageButton.resolve({ rect = cardRect, scale = selectorCanvas.scale })
      genderSlots[index - 1] = {
        key = sourceGender,
        rect = cardRect,
        scale = selectorCanvas.scale,
        portraitId = "gender_" .. sourceGender,
        portraitRect = portrait,
        button = button,
      }
    end
    if view.phase == "gender_select" then
      result.genderButtons = genderSlots
    else
      local sourceGender = view.genderFocus == 0 and "male" or "female"
      local sourceCard = assert(manifest.genderSelector.buttons[sourceGender]).bounds
      local group = genderConfirmationEntries(assert(selectorRegion), sourceCard, sourceGender, manifest)
      result.selectedProfileButton = group.card
      if view.confirmationChoice then
        result.confirmationButtons = group.confirmation
      end
    end
  end
  if view.phase == "name_confirm" and view.confirmationChoice and view.confirmationChoice.kind == "name" then
    result.confirmationButtons = nameConfirmationEntries(assert(nameStage), assert(nameChoiceRegion))
  end
  if view.phase == "name_edit" then
    local previewHeight = math.min(220, math.max(48, math.floor(sceneContent.height * 0.28)))
    previewHeight = math.min(previewHeight, math.floor(sceneContent.height * 0.40))
    local keyboard = rect(
      sceneContent.x,
      sceneContent.y + previewHeight + gap,
      sceneContent.width,
      sceneContent.height - previewHeight - gap
    )
    local keys, columns = view.virtualKeys or {}, math.min(10, math.max(1, view.virtualKeyColumns or 10))
    local keyGap = clamp(math.floor(math.min(keyboard.width, keyboard.height) * 0.015 + 0.5), 4, 10)
    local rows = math.max(1, math.ceil(#keys / columns))
    local keyHeight = (keyboard.height - keyGap * (rows - 1)) / rows
    for index, key in ipairs(keys) do
      local row, column = math.floor((index - 1) / columns), (index - 1) % columns
      local count = math.min(columns, #keys - row * columns)
      local keyWidth = (keyboard.width - keyGap * (count - 1)) / count
      result.nameKeys[index] = {
        rect = rect(
          keyboard.x + column * (keyWidth + keyGap),
          keyboard.y + row * (keyHeight + keyGap),
          keyWidth,
          keyHeight
        ),
        kind = key.kind,
        glyph = key.glyph,
        label = key.kind == "glyph" and key.glyph or key.kind == "delete" and "Delete" or "Confirm",
      }
    end
    result.nameGrid, result.namePreview =
      result.nameKeys, rect(sceneContent.x, sceneContent.y, sceneContent.width, previewHeight)
  end
  return result
end

---@param region table?
---@param x number
---@param y number
---@return boolean
function OakIntroLayout.contains(region, x, y)
  return region ~= nil
    and x >= region.x
    and y >= region.y
    and x < region.x + region.width
    and y < region.y + region.height
end

return OakIntroLayout
