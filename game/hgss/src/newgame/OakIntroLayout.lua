-- Pure host-native geometry for the Oak intro. Source dimensions are semantic
-- placement relationships, never a fixed render surface.

local OakIntroLayout = {}
local Button = require("libs.ui.src.Button")

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

local function containedPanel(region, aspect)
  local width = math.min(region.width, region.height * aspect)
  local height = width / aspect
  if height > region.height then
    height = region.height
    width = height * aspect
  end
  return rect(region.x + (region.width - width) / 2, region.y + (region.height - height) / 2, width, height)
end

---@param widgetValue { width: number, height: number }
---@param contentRect { x: number, y: number, width: number, height: number }
---@return { x: number, y: number, width: number, height: number, scale: number }
local function fitWidget(widgetValue, contentRect)
  local scale = math.min(contentRect.width / widgetValue.width, contentRect.height / widgetValue.height)
  assert(scale > 0, "Oak profile art scale must be positive")
  local width, height = widgetValue.width * scale, widgetValue.height * scale
  return {
    x = contentRect.x + (contentRect.width - width) / 2,
    y = contentRect.y + (contentRect.height - height) / 2,
    width = width,
    height = height,
    scale = scale,
  }
end

local function buttonMetrics(buttonRect)
  local minimum = math.min(buttonRect.width, buttonRect.height)
  local bevel = math.min(5, math.max(1, math.floor(minimum * 0.035 + 0.5)))
  local inset = math.min(10, math.max(2, math.floor(minimum * 0.04 + 0.5)))
  return bevel, inset, inset
end

local function resolveButton(buttonRect)
  local bevel, contentInsetX, contentInsetY = buttonMetrics(buttonRect)
  return Button.resolve({
    rect = buttonRect,
    bevelWidth = bevel,
    contentInsetX = contentInsetX,
    contentInsetY = contentInsetY,
  })
end

local function splitVertical(region, gap)
  local height = (region.height - gap) / 2
  assert(height > 0, "Oak confirmation buttons do not fit their region")
  return {
    resolveButton(rect(region.x, region.y, region.width, height)),
    resolveButton(rect(region.x, region.y + height + gap, region.width, height)),
  }
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
  local inset = math.min(12, math.floor(minimum * 0.035 + 0.5), math.floor((minimum - 1) / 2))
  local safeFrame = rect(inset, inset, width - inset * 2, height - inset * 2)
  local gap = math.min(8, math.max(0, math.floor(minimum * 0.02 + 0.5)))
  local reservesDialogue = view.dialogue ~= nil
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
  local selectorActive = view.phase == "gender_select" or view.phase == "gender_confirm"
  local compositionProgress = view.genderCompositionProgress
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
  if compositionActive then
    oakRegion, selectorRegion = selectorRegions(scene, gap)
    result.oakRegion, result.selectorRegion = oakRegion, selectorRegion
    if subjectId == "oak" then
      result.subject = composedOakRect(assert(result.subject), assert(subjectWidget), oakRegion, compositionProgress)
    end
  end
  if view.revealWidget then
    local revealWidget = widget(manifest, view.revealWidget)
    result.revealCanvas = canvas
    result.reveal = revealRect(revealWidget, canvas)
  end
  if selectorActive then
    local selectorMinimum = math.min(selectorRegion.width, selectorRegion.height)
    local selectorInset = math.min(
      32,
      math.max(gap, math.floor(selectorMinimum * 0.05 + 0.5)),
      math.max(0, math.floor((selectorMinimum - 1) / 2))
    )
    local insetRegion = rect(
      selectorRegion.x + selectorInset,
      selectorRegion.y + selectorInset,
      selectorRegion.width - selectorInset * 2,
      selectorRegion.height - selectorInset * 2
    )
    result.selectorInset = selectorInset
    result.selectorPanel = containedPanel(insetRegion, 4 / 3)
    local panel = assert(result.selectorPanel)
    local panelMinimum = math.min(panel.width, panel.height)
    local outerInset = math.min(24, math.max(6, math.floor(panelMinimum * 0.06 + 0.5)))
    local controlGap = math.min(24, math.max(8, math.floor(panel.width * 0.04 + 0.5)))
    outerInset = math.min(outerInset, (math.min(panel.width, panel.height) - 1) / 2)
    local columnWidth = (panel.width - outerInset * 2 - controlGap) / 2
    assert(columnWidth > 0, "Oak gender buttons do not fit their panel")
    local genderSlots = {}
    for gender, id in ipairs({ "male", "female" }) do
      local buttonRect = rect(
        panel.x + outerInset + (gender - 1) * (columnWidth + controlGap),
        panel.y + outerInset,
        columnWidth,
        panel.height - outerInset * 2
      )
      local button = resolveButton(buttonRect)
      local portrait = fitWidget(widget(manifest, "gender_" .. id), button.contentRect)
      genderSlots[gender - 1] = {
        key = id,
        button = button,
        portraitId = "gender_" .. id,
        portraitRect = portrait,
      }
    end
    if view.phase == "gender_select" then
      result.genderButtons = genderSlots
    else
      result.selectedProfileButton = assert(genderSlots[view.genderFocus])
    end
  end
  if view.confirmationChoice then
    if view.phase == "gender_confirm" then
      local panel = assert(result.selectorPanel)
      local selectedColumn = view.genderFocus
      local selectedProfileButton = assert(result.selectedProfileButton)
      assert(selectedProfileButton.key == (selectedColumn == 0 and "male" or "female"))
      local controlGap = math.min(24, math.max(8, math.floor(panel.width * 0.04 + 0.5)))
      local confirmationColumn = selectedColumn == 0 and 1 or 0
      local columnWidth = selectedProfileButton.button.rect.width
      local columnX = panel.x
        + (panel.width - columnWidth * 2 - controlGap) / 2
        + confirmationColumn * (columnWidth + controlGap)
      local columnRegion =
        rect(columnX, selectedProfileButton.button.rect.y, columnWidth, selectedProfileButton.button.rect.height)
      local gapSize = math.min(16, math.max(6, math.floor(columnRegion.height * 0.06 + 0.5)))
      local buttons = splitVertical(columnRegion, gapSize)
      result.confirmationButtons = {
        [0] = { key = "yes", button = buttons[1] },
        [1] = { key = "no", button = buttons[2] },
      }
    elseif view.phase == "name_confirm" then
      local sceneMinimum = math.min(sceneContent.width, sceneContent.height)
      local stackWidth = math.min(sceneContent.width * 0.5, 280)
      local stackHeight = math.min(sceneContent.height * 0.36, 180)
      local gapSize = math.min(16, math.max(6, math.floor(sceneMinimum * 0.02 + 0.5)))
      stackHeight = math.max(stackHeight, gapSize + 2)
      local panel = rect(
        sceneContent.x + (sceneContent.width - stackWidth) / 2,
        sceneContent.y + sceneContent.height - stackHeight,
        stackWidth,
        stackHeight
      )
      local buttons = splitVertical(panel, gapSize)
      result.confirmationButtons = {
        [0] = { key = "yes", button = buttons[1] },
        [1] = { key = "no", button = buttons[2] },
      }
    end
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
