-- Pure host-native geometry for the Oak intro. Source dimensions are semantic
-- placement relationships, never a fixed render surface.

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

local function sourcePoint(reference, point, region)
  return {
    x = region.x + point.x / reference.width * region.width,
    y = region.y + point.y / reference.height * region.height,
  }
end

local function imageAtPoint(asset, point, bounds)
  local left = asset.anchor.x > 0 and (point.x - bounds.x) / asset.anchor.x or math.huge
  local top = asset.anchor.y > 0 and (point.y - bounds.y) / asset.anchor.y or math.huge
  local right = asset.anchor.x < asset.width and (bounds.x + bounds.width - point.x) / (asset.width - asset.anchor.x)
    or math.huge
  local bottom = asset.anchor.y < asset.height
      and (bounds.y + bounds.height - point.y) / (asset.height - asset.anchor.y)
    or math.huge
  local scale = math.min(left, top, right, bottom, 6)
  assert(scale > 0 and scale < math.huge, "Oak widget does not fit its source point")
  return {
    x = point.x - asset.anchor.x * scale,
    y = point.y - asset.anchor.y * scale,
    width = asset.width * scale,
    height = asset.height * scale,
    scale = scale,
  }
end

local function sourceAligned(asset, reference, sourceRegion)
  local point = sourcePoint(
    reference,
    { x = asset.sourceBounds.x + asset.anchor.x, y = asset.sourceBounds.y + asset.anchor.y },
    sourceRegion
  )
  return imageAtPoint(asset, point, sourceRegion)
end

local function sourceCentered(asset, reference, sourceRegion)
  assert(asset.sourceCenter, "Oak widget source center is missing")
  return imageAtPoint(asset, sourcePoint(reference, asset.sourceCenter, sourceRegion), sourceRegion)
end

local function selectorRegions(safeFrame, gap)
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

---@param width number
---@param height number
---@param view table
---@param glyphs string[]
---@param manifest table
---@return table
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
  local result = {
    viewport = rect(0, 0, width, height),
    safeFrame = safeFrame,
    scene = scene,
    stage = scene,
    stageContent = sceneContent,
    dialogue = dialogue,
    message = dialogue and dialogue.outerRect or scene,
    cards = {},
    profileCards = {},
    genderChoices = {},
    nameGrid = {},
    nameKeys = {},
    genderFocus = view.genderFocus,
  }
  local oak = widget(manifest, "oak")
  local selectorActive = view.phase == "gender_select" or view.phase == "gender_confirm"
  if selectorActive then
    local oakRegion, selectorRegion = selectorRegions(scene, gap)
    result.oakRegion, result.selectorRegion = oakRegion, selectorRegion
    result.subject = sourceAligned(oak, reference, oakRegion)
    result.selectorPanel = containedPanel(selectorRegion, 4 / 3)
    result.genderBackground = sourceAligned(widget(manifest, "gender_background"), reference, result.selectorPanel)
    for gender, id in pairs({ [0] = "gender_male", [1] = "gender_female" }) do
      result.genderChoices[gender] = sourceCentered(widget(manifest, id), reference, result.selectorPanel)
    end
    result.genderHitRegions = result.genderChoices
    result.cards, result.profileCards = result.genderChoices, result.genderChoices
  else
    local oakPoint =
      sourcePoint(reference, { x = oak.sourceBounds.x + oak.anchor.x, y = oak.sourceBounds.y + oak.anchor.y }, scene)
    result.subject = imageAtPoint(oak, oakPoint, scene)
    local maximumDisplacement = math.min(52 * result.subject.scale, sceneContent.width * 0.24)
    local displacement = maximumDisplacement * ((view.oakSlideOffset or 0) / -52)
    result.subject.x = result.subject.x - displacement
    if view.revealWidget then
      result.reveal = sourceCentered(widget(manifest, view.revealWidget), reference, scene)
    end
  end
  if view.confirmationChoice then
    local panelHeight = math.min(math.max(94, sceneContent.height * 0.32), sceneContent.height)
    local panelWidth = math.min(sceneContent.width * 0.62, 520)
    local panel = rect(
      sceneContent.x + (sceneContent.width - panelWidth) / 2,
      sceneContent.y + sceneContent.height - panelHeight,
      panelWidth,
      panelHeight
    )
    local rowGap = math.min(12, math.max(6, math.floor(panel.height * 0.06 + 0.5)))
    local rowHeight = (panel.height - rowGap) / 2
    result.choicePanel = panel
    result.choiceRows = {
      [0] = rect(panel.x, panel.y, panel.width, rowHeight),
      [1] = rect(panel.x, panel.y + rowHeight + rowGap, panel.width, rowHeight),
    }
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
