-- Persists validated field saves through a version-scoped SaveFs rooted in the
-- persistent user-data namespace, outside the disposable version cache. The
-- cache owner is rejected at construction so a wiring mistake cannot move
-- saves back under the ROM/cache deletion root. Publication is transactional:
-- serialize to a temporary sibling, then atomically replace the stable save
-- path. Loading and saving both use the one current schema.

local FieldSave = require("libs.engine.src.FieldSave")
local SaveFs = require("libs.storage.src.SaveFs")

local FieldSaveStore = {}
FieldSaveStore.__index = FieldSaveStore

local TEMP_PATH = FieldSave.PATH .. ".tmp"

---@class FieldSaveStore
---@field saveFs SaveFs
---@field opts table

---@param saveFs SaveFs
---@param opts table?
function FieldSaveStore.new(saveFs, opts)
  assert(getmetatable(saveFs) == SaveFs, "field save SaveFs required")
  return setmetatable({ saveFs = saveFs, opts = opts or {} }, FieldSaveStore)
end

function FieldSaveStore:load()
  local record, loadErr = self.saveFs:loadLua(FieldSave.PATH)
  if not record then
    return nil, loadErr
  end
  return FieldSave.validate(record, self.opts)
end

function FieldSaveStore:save(record)
  local valid, validationErr = FieldSave.validate(record, self.opts)
  if not valid then
    error(validationErr)
  end
  self.saveFs:writeLua(TEMP_PATH, valid)
  self.saveFs:replace(TEMP_PATH, FieldSave.PATH)
  return true
end

function FieldSaveStore:reset()
  self.saveFs:remove(TEMP_PATH)
  self.saveFs:remove(FieldSave.PATH)
  return true
end

return FieldSaveStore
