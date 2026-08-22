-- Responsive renderer for the product Main Menu. It consumes the state view
-- and its precomputed rectangles; it never performs hit testing or persistence.

---@class MainMenuRenderer
---@field new fun(): MainMenuRenderer
---@field draw fun(self: MainMenuRenderer, view: table)
---@field dispose? fun(self: MainMenuRenderer)
local MainMenuRenderer = {}
MainMenuRenderer.__index = MainMenuRenderer

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

  for _, item in ipairs(view.items) do
    local card = layout.cards[item.id]
    if
      card
      and card.body.y + card.body.height >= layout.viewport.y
      and card.body.y <= layout.viewport.y + layout.viewport.height
    then
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
        lg.setColor(0.28, 0.18, 0.22, 1)
        lg.rectangle("fill", card.delete.x, card.delete.y, card.delete.width, card.delete.height)
        lg.setColor(1, 0.8, 0.8, 1)
        lg.printf("Delete", card.delete.x, card.delete.y + 14, card.delete.width, "center")
      end
    end
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
    lg.setColor(view.dialog.focusedAction == "cancel" and 0.3 or 0.2, 0.35, 0.45, 1)
    lg.rectangle("fill", dialog.cancel.x, dialog.cancel.y, dialog.cancel.width, dialog.cancel.height)
    lg.setColor(view.dialog.focusedAction == "delete" and 0.55 or 0.3, 0.2, 0.25, 1)
    lg.rectangle("fill", dialog.delete.x, dialog.delete.y, dialog.delete.width, dialog.delete.height)
    lg.setColor(1, 1, 1, 1)
    lg.printf("Cancel", dialog.cancel.x, dialog.cancel.y + 10, dialog.cancel.width, "center")
    lg.printf("Delete", dialog.delete.x, dialog.delete.y + 10, dialog.delete.width, "center")
  elseif view.catalogError then
    lg.setColor(1, 0.65, 0.65, 1)
    lg.print("Save catalog unavailable: " .. tostring(view.catalogError), layout.viewport.x, layout.viewport.y - 24)
  end
end

return MainMenuRenderer
