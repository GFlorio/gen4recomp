-- Pure Main Menu interaction state. It owns semantic focus, primary actions,
-- and the separate delete confirmation without knowing about storage or LÖVE.

---@class MainMenuController
local MainMenuController = {}
MainMenuController.__index = MainMenuController

local function indexOf(items, id)
  for index, item in ipairs(items) do
    if item.id == id then
      return index
    end
  end
  return nil
end

local function canDelete(item)
  return item ~= nil and item.canDelete == true and item.saveId ~= nil
end

---@param items table[]
---@return MainMenuController
function MainMenuController.new(items)
  assert(type(items) == "table" and #items > 0, "the Main Menu needs at least New Game")
  return setmetatable({ items = items, focusIndex = 1, dialog = nil }, MainMenuController)
end

function MainMenuController:setItems(items)
  assert(type(items) == "table" and #items > 0, "the Main Menu needs at least New Game")
  local oldIndex = self.focusIndex
  local oldId = self:focusedId()
  local preserved = indexOf(items, oldId)
  self.items = items
  self.focusIndex = preserved or math.min(oldIndex, #items)
end

function MainMenuController:setFocusedId(id)
  local index = assert(indexOf(self.items, id), "cannot focus an unknown Main Menu item")
  self.focusIndex = index
end

function MainMenuController:focusedId()
  return self.items[self.focusIndex].id
end

function MainMenuController:focusedItem()
  return self.items[self.focusIndex]
end

function MainMenuController:move(direction)
  assert(direction == "up" or direction == "down", "unknown Main Menu direction")
  local delta = direction == "up" and -1 or 1
  self.focusIndex = math.max(1, math.min(#self.items, self.focusIndex + delta))
end

function MainMenuController:requestDelete()
  local item = self:focusedItem()
  if not canDelete(item) then
    return false
  end
  self.dialog = { kind = "delete", saveId = item.saveId, focusedAction = "cancel" }
  return true
end

function MainMenuController:toggleDialogAction()
  if self.dialog then
    self.dialog.focusedAction = self.dialog.focusedAction == "cancel" and "delete" or "cancel"
  end
end

function MainMenuController:chooseDialogAction(action)
  assert(action == "cancel" or action == "delete", "unknown delete dialog action")
  if self.dialog then
    self.dialog.focusedAction = action
  end
end

function MainMenuController:cancelDelete()
  self.dialog = nil
end

---@return string|nil saveId
function MainMenuController:confirmDelete()
  if not self.dialog or self.dialog.focusedAction ~= "delete" then
    return nil
  end
  local saveId = self.dialog.saveId
  self.dialog = nil
  return saveId
end

return MainMenuController
