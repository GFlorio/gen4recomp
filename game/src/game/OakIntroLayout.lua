-- Pure host-native geometry for the Oak intro. Source dimensions never define
-- the stage; semantic widgets and the current mode do.

local OakIntroLayout = {}

local OAK_SLIDE_DISTANCE = 52

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function rect(x, y, width, height)
  assert(width > 0 and height > 0, "Oak layout rectangle must be positive")
  return { x = x, y = y, width = width, height = height }
end

local function metricsFor(metrics, widgetId)
  local asset = metrics and metrics[widgetId]
  if asset == nil then
    return nil
  end
  assert(asset.width > 0 and asset.height > 0 and asset.anchor, "Oak widget metrics are invalid")
  return asset
end

local function contain(asset, slot, anchorX, anchorY)
  local scale = math.min(slot.width / asset.width, slot.height / asset.height, 6)
  assert(scale > 0, "Oak widget does not fit its slot")
  return {
    x = anchorX - asset.anchor.x * scale,
    y = anchorY - asset.anchor.y * scale,
    width = asset.width * scale,
    height = asset.height * scale,
    scale = scale,
  }
end

local function topologySurfaces(topology)
  if topology == nil then
    return nil, nil
  end
  assert(type(topology) == "table" and type(topology.surfaces) == "table", "Oak screen topology is invalid")
  local world, auxiliary
  for _, surface in ipairs(topology.surfaces) do
    if surface.role == "world" then
      assert(world == nil, "Oak topology has multiple world surfaces")
      world = surface
    elseif surface.role == "auxiliary" then
      assert(auxiliary == nil, "Oak topology has multiple auxiliary surfaces")
      auxiliary = surface
    end
  end
  return world, auxiliary
end

local function selectorRegions(safeFrame, width, height, topology)
  local world, auxiliary = topologySurfaces(topology)
  if world and auxiliary then
    return world.safeRect, auxiliary.safeRect
  end
  if height > width * 1.2 then
    local mainHeight = math.floor(safeFrame.height * 0.56)
    return rect(safeFrame.x, safeFrame.y, safeFrame.width, mainHeight),
      rect(safeFrame.x, safeFrame.y + mainHeight, safeFrame.width, safeFrame.height - mainHeight)
  end
  if width >= height * 1.5 then
    local mainWidth = math.floor(safeFrame.width * 0.56)
    return rect(safeFrame.x, safeFrame.y, mainWidth, safeFrame.height),
      rect(safeFrame.x + mainWidth, safeFrame.y, safeFrame.width - mainWidth, safeFrame.height)
  end
  local auxiliaryHeight = math.max(96, math.floor(safeFrame.height * 0.58))
  auxiliaryHeight = math.min(auxiliaryHeight, safeFrame.height - 48)
  return rect(safeFrame.x, safeFrame.y, safeFrame.width, safeFrame.height - auxiliaryHeight),
    rect(safeFrame.x, safeFrame.y + safeFrame.height - auxiliaryHeight, safeFrame.width, auxiliaryHeight)
end

---@param width number
---@param height number
---@param view table
---@param glyphs string[]
---@param metrics table<string, table>?
---@param screenTopology ScreenTopology?
---@return table
function OakIntroLayout.compute(width, height, view, glyphs, metrics, screenTopology)
  assert(
    type(width) == "number"
      and width == width
      and width > 0
      and type(height) == "number"
      and height == height
      and height > 0,
    "Oak viewport is invalid"
  )
  assert(type(view) == "table" and type(glyphs) == "table", "Oak layout requires view and glyphs")
  local inset = clamp(math.floor(math.min(width, height) * 0.035 + 0.5), 12, 40)
  local safeFrame = rect(inset, inset, width - inset * 2, height - inset * 2)
  local gap = clamp(math.floor(math.min(width, height) * 0.02 + 0.5), 8, 24)
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
  local selectorActive = view.phase == "gender_select" or view.phase == "gender_confirm"
  local mainRegion, auxiliaryRegion
  if selectorActive then
    mainRegion, auxiliaryRegion = selectorRegions(safeFrame, width, height, screenTopology)
  end
  local stage = mainRegion or rect(safeFrame.x, safeFrame.y, safeFrame.width, safeFrame.height)
  local contentWidth = math.min(stage.width, 1120)
  local stageContent = rect(stage.x + (stage.width - contentWidth) / 2, stage.y, contentWidth, stage.height)
  local result = {
    viewport = rect(0, 0, width, height),
    safeFrame = safeFrame,
    stage = stage,
    stageContent = stageContent,
    dialogue = dialogue,
    message = dialogue and dialogue.outerRect or stage,
    cards = {},
    profileCards = {},
    genderChoices = {},
    nameGrid = {},
    nameKeys = {},
    genderFocus = view.genderFocus,
    mainRegion = mainRegion,
    auxiliaryRegion = auxiliaryRegion,
  }
  local oak = metricsFor(metrics, "oak")
  if oak then
    local slot = rect(
      stageContent.x + stageContent.width * 0.21,
      stageContent.y,
      stageContent.width * 0.58,
      stageContent.height * 0.88
    )
    local oakScale = math.min(slot.width / oak.width, slot.height / oak.height, 6)
    local maximumDisplacement = math.min(OAK_SLIDE_DISTANCE * oakScale, stageContent.width * 0.24)
    local displacement = maximumDisplacement * ((view.oakSlideOffset or 0) / -OAK_SLIDE_DISTANCE)
    local anchorY = stageContent.y + stageContent.height - clamp(math.floor(stageContent.height * 0.04 + 0.5), 4, 24)
    result.subject = contain(oak, slot, stageContent.x + stageContent.width / 2 - displacement, anchorY)
  else
    result.subject = stageContent
  end
  if view.revealWidget then
    local reveal = assert(metricsFor(metrics, view.revealWidget), "Oak reveal widget metrics are missing")
    local anchorX, anchorY = stageContent.x + stageContent.width / 2, stageContent.y + stageContent.height * 0.60
    result.reveal = contain(
      reveal,
      rect(
        stageContent.x + stageContent.width * 0.34,
        stageContent.y,
        stageContent.width * 0.32,
        stageContent.height * 0.44
      ),
      anchorX,
      anchorY
    )
  end
  if selectorActive then
    local selector = assert(auxiliaryRegion)
    local background = assert(metricsFor(metrics, "gender_background"), "Oak gender background metrics are missing")
    result.genderBackground =
      contain(background, selector, selector.x + selector.width / 2, selector.y + selector.height / 2)
    local choiceGap = clamp(math.floor(selector.width * 0.04 + 0.5), 8, 24)
    local choiceWidth = (selector.width - choiceGap) / 2
    local choiceHeight = selector.height * 0.78
    local male = assert(metricsFor(metrics, "gender_male"), "Oak male selector metrics are missing")
    local female = assert(metricsFor(metrics, "gender_female"), "Oak female selector metrics are missing")
    local choiceY = selector.y + selector.height * 0.11
    local choiceAnchorY = choiceY + choiceHeight
    result.genderChoices[0] =
      contain(male, rect(selector.x, choiceY, choiceWidth, choiceHeight), selector.x + choiceWidth / 2, choiceAnchorY)
    result.genderChoices[1] = contain(
      female,
      rect(selector.x + choiceWidth + choiceGap, choiceY, choiceWidth, choiceHeight),
      selector.x + choiceWidth + choiceGap + choiceWidth / 2,
      choiceAnchorY
    )
    result.genderHitRegions = result.genderChoices
    result.cards = result.genderChoices
    result.profileCards = result.genderChoices
  end
  if view.confirmationChoice then
    local panelHeight = math.min(stageContent.height * 0.32, 180)
    panelHeight = math.max(94, panelHeight)
    panelHeight = math.min(panelHeight, stageContent.height)
    local panelWidth = math.min(stageContent.width * 0.62, 520)
    local panel = rect(
      stageContent.x + (stageContent.width - panelWidth) / 2,
      stageContent.y + stageContent.height - panelHeight,
      panelWidth,
      panelHeight
    )
    local rowGap = clamp(math.floor(panel.height * 0.06 + 0.5), 6, 12)
    local rowHeight = (panel.height - rowGap) / 2
    result.choicePanel = panel
    result.choiceRows = {
      [0] = rect(panel.x, panel.y, panel.width, rowHeight),
      [1] = rect(panel.x, panel.y + rowHeight + rowGap, panel.width, rowHeight),
    }
  end
  if view.phase == "name_edit" then
    local previewHeight = math.min(220, math.max(48, math.floor(stageContent.height * 0.28)))
    previewHeight = math.min(previewHeight, math.floor(stageContent.height * 0.40))
    local keyboard = rect(
      stageContent.x,
      stageContent.y + previewHeight + gap,
      stageContent.width,
      stageContent.height - previewHeight - gap
    )
    local keys, columns = view.virtualKeys or {}, math.min(10, math.max(1, view.virtualKeyColumns or 10))
    local keyGap = clamp(math.floor(math.min(keyboard.width, keyboard.height) * 0.015 + 0.5), 4, 10)
    local rows = math.max(1, math.ceil(#keys / columns))
    local keyHeight = (keyboard.height - keyGap * (rows - 1)) / rows
    for index, key in ipairs(keys) do
      local zero, row, column = index - 1, math.floor((index - 1) / columns), (index - 1) % columns
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
      result.nameKeys, rect(stageContent.x, stageContent.y, stageContent.width, previewHeight)
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
