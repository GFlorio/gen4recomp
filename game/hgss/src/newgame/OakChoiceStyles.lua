-- Oak-specific paint policy for source-backed profile cards and confirmations.

local OakChoiceStyles = {}

local SELECTED_ACCENT = { 31, 7, 7 }
local UNSELECTED_ACCENT = { 27, 28, 28 }

local function clamp(value, low, high)
  return math.max(low, math.min(high, value))
end

local function expandChannel(value)
  return math.floor((value * 255 + 15) / 31) / 255
end

local function accentTint(accent)
  return {
    r = expandChannel(accent[1]),
    g = expandChannel(accent[2]),
    b = expandChannel(accent[3]),
    a = 1,
  }
end

local function toneTint(selector, selected, delta)
  if not selected then
    return {
      r = selector.defaultTone.r / 255,
      g = selector.defaultTone.g / 255,
      b = selector.defaultTone.b / 255,
      a = 1,
    }
  end
  local channel = expandChannel(clamp(16 + delta, 0, 31))
  return { r = channel, g = channel, b = channel, a = 1 }
end

function OakChoiceStyles.paintProfileChoice(paintList, item, selected, context)
  local payload = assert(item.payload)
  local button = assert(payload.button)
  local buttonRect = assert(payload.buttonRect)
  local gender = assert(payload.portraitId)
  local selector = assert(context.selector)
  local delta = assert(context.focusBlinkDelta)
  paintList:image("genderSelector." .. gender .. ".backing", buttonRect)
  paintList:image("genderSelector." .. gender .. ".pulseMask", buttonRect, toneTint(selector, selected, delta))
  paintList:image(
    "genderSelector." .. gender .. ".accentMask",
    buttonRect,
    accentTint(selected and SELECTED_ACCENT or UNSELECTED_ACCENT)
  )
  paintList:image(payload.portraitId, payload.portraitRect)
  assert(button.backing and button.pulseMask and button.accentMask)
end

function OakChoiceStyles.paintStaticProfileCard(paintList, item, context)
  OakChoiceStyles.paintProfileChoice(paintList, item, true, {
    selector = context.selector,
    focusBlinkDelta = 0,
  })
end

function OakChoiceStyles.paintConfirmationChoice(paintList, item, selected, context)
  local payload = assert(item.payload)
  local gender = assert(context.gender)
  local choice = assert(item.key)
  paintList:image("profileConfirmation." .. gender .. "." .. choice .. ".base", item.rect)
  if selected then
    paintList:image("profileConfirmation." .. gender .. "." .. choice .. ".focus", item.rect)
  end
  paintList:centeredText(assert(context.labels[item.index]), payload.textRect, assert(payload.textScale))
end

return OakChoiceStyles
