-- Responsive renderer for the product Main Menu. It consumes the state view
-- and its precomputed rectangles; it never performs hit testing or persistence.

local Button = require("libs.ui.src.Button")
local ButtonPainter = require("game.hgss.src.ui.ButtonPainter")

---@class MainMenuRenderer
---@field new fun(): MainMenuRenderer
---@field draw fun(self: MainMenuRenderer, view: table)
---@field dispose? fun(self: MainMenuRenderer)
local MainMenuRenderer = {}
MainMenuRenderer.__index = MainMenuRenderer

local BUTTON_BORDER_WIDTH = 1
local BUTTON_RIM_WIDTH = 1
local BUTTON_INNER_BORDER_WIDTH = 1
local BUTTON_CORNER_CUT = 1
local BUTTON_FACE_SPLIT = 0.5
local BUTTON_CONTENT_INSET_X = 4
local BUTTON_CONTENT_INSET_Y = 2

local function actionButton(rect)
  local minimum = math.min(rect.width, rect.height)
  local layerWidth = math.min(1, math.max(0, (minimum - 1) / 6))
  local cornerCut = math.min(1, math.max(0, (minimum - 1) / 2))
  local totalLayerWidth = layerWidth * 3
  return Button.resolve({
    rect = rect,
    borderWidth = math.min(BUTTON_BORDER_WIDTH, layerWidth),
    rimWidth = math.min(BUTTON_RIM_WIDTH, layerWidth),
    innerBorderWidth = math.min(BUTTON_INNER_BORDER_WIDTH, layerWidth),
    cornerCut = math.min(BUTTON_CORNER_CUT, cornerCut),
    faceSplit = BUTTON_FACE_SPLIT,
    contentInsetX = math.min(BUTTON_CONTENT_INSET_X, math.max(0, (rect.width - totalLayerWidth * 2 - 1) / 2)),
    contentInsetY = math.min(BUTTON_CONTENT_INSET_Y, math.max(0, (rect.height - totalLayerWidth * 2 - 1) / 2)),
  })
end

local function drawActionButton(rect, label, textColor, faceColor, highlightColor, shadowColor)
  local button = actionButton(rect)
  local lg = love.graphics
  ButtonPainter.draw(lg, button, {
    border = shadowColor,
    rim = highlightColor,
    innerBorder = highlightColor,
    faceTop = faceColor,
    faceBottom = faceColor,
  })
  lg.setColor(textColor[1], textColor[2], textColor[3], textColor[4])
  lg.printf(
    label,
    button.contentRect.x,
    button.contentRect.y + math.floor((button.contentRect.height - 14) / 2),
    button.contentRect.width,
    "center"
  )
end

local function cardTitle(item)
  if item.id == "new-game" then
    return "New Game"
  end
  return item.playerName or "Save unavailable"
end

function MainMenuRenderer.new()
  return setmetatable({}, MainMenuRenderer)
end

---@param view table
function MainMenuRenderer:draw(view)
  local lg = love.graphics
  local layout = view.layout
  lg.setColor(0.08, 0.1, 0.15, 1)
  lg.clear(0.08, 0.1, 0.15, 1)

  lg.setColor(1, 1, 1, 1)
  lg.print("g4recomp", layout.viewport.x, 16)

  local oldX, oldY, oldWidth, oldHeight = lg.getScissor()
  lg.setScissor(layout.content.x, layout.content.y, layout.content.width, layout.content.height)
  local cardsOk, cardsError = xpcall(function()
    if view.catalogError and view.catalogError ~= "" then
      local errorRect = assert(layout.catalogErrorRect, "catalog error needs visible layout geometry")
      lg.setColor(1, 0.65, 0.65, 1)
      lg.setScissor(errorRect.x, errorRect.y, errorRect.width, errorRect.height)
      lg.printf(
        "Save catalog unavailable: " .. tostring(view.catalogError),
        errorRect.x + 8,
        errorRect.y + 4,
        math.max(1, errorRect.width - 16),
        "left"
      )
      lg.setScissor(layout.content.x, layout.content.y, layout.content.width, layout.content.height)
    end
    for _, item in ipairs(view.items) do
      local card = layout.cards[item.id]
      if card then
        local focused = item.id == view.focusedId
        local enabled = item.id == "new-game" or item.canContinue
        lg.setColor(focused and 0.25 or 0.16, focused and 0.4 or 0.19, focused and 0.6 or 0.25, 1)
        lg.rectangle("fill", card.body.x, card.body.y, card.body.width, card.body.height)
        if focused then
          lg.setColor(0.7, 0.9, 1, 1)
          lg.setLineWidth(2)
          lg.rectangle("line", card.body.x, card.body.y, card.body.width, card.body.height)
        end

        lg.setColor(enabled and 1 or 0.75, enabled and 1 or 0.75, enabled and 1 or 0.8, 1)
        lg.print(cardTitle(item), card.body.x + 12, card.body.y + 7)
        if item.id == "new-game" then
          lg.setColor(0.7, 0.75, 0.82, 1)
          lg.print("Start a new adventure", card.body.x + 12, card.body.y + 25)
        elseif item.canContinue then
          lg.setColor(0.7, 0.75, 0.82, 1)
          lg.print(item.playTimeLabel, card.body.x + 12, card.body.y + 25)
        else
          lg.setColor(1, 0.65, 0.65, 1)
          lg.print(item.errorSummary or "Save unavailable", card.body.x + 12, card.body.y + 25)
        end

        if card.delete then
          drawActionButton(
            card.delete,
            "Delete",
            { 1, 0.8, 0.8, 1 },
            { 0.28, 0.18, 0.22, 1 },
            { 0.45, 0.3, 0.34, 1 },
            { 0.12, 0.08, 0.1, 1 }
          )
        end
      end
    end
  end, debug.traceback)
  if oldX ~= nil then
    lg.setScissor(oldX, oldY, oldWidth, oldHeight)
  else
    lg.setScissor()
  end
  if not cardsOk then
    error(cardsError, 0)
  end

  if view.dialog then
    local dialog = layout.dialog
    lg.setColor(0, 0, 0, 0.72)
    lg.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())
    lg.setColor(0.12, 0.15, 0.22, 1)
    lg.rectangle("fill", dialog.box.x, dialog.box.y, dialog.box.width, dialog.box.height)
    lg.setColor(1, 1, 1, 1)
    lg.printf("Delete this save?", dialog.box.x + 12, dialog.box.y + 14, dialog.box.width - 24, "center")
    lg.setColor(0.75, 0.8, 0.88, 1)
    lg.printf("" .. tostring(view.dialog.saveId), dialog.box.x + 12, dialog.box.y + 38, dialog.box.width - 24, "center")
    drawActionButton(
      dialog.cancel,
      "Cancel",
      { 1, 1, 1, 1 },
      { view.dialog.focusedAction == "cancel" and 0.3 or 0.2, 0.35, 0.45, 1 },
      { 0.55, 0.65, 0.8, 1 },
      { 0.08, 0.1, 0.15, 1 }
    )
    drawActionButton(
      dialog.delete,
      "Delete",
      { 1, 1, 1, 1 },
      { view.dialog.focusedAction == "delete" and 0.55 or 0.3, 0.2, 0.25, 1 },
      { 0.8, 0.45, 0.45, 1 },
      { 0.18, 0.08, 0.1, 1 }
    )
  end
end

return MainMenuRenderer
