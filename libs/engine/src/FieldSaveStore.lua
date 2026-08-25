-- Persists field saves through a version-scoped SaveFs rooted in the
-- persistent user-data namespace, outside the disposable version cache. The
-- cache owner is rejected at construction so a wiring mistake cannot move
-- saves back under the ROM/cache deletion root. Publication is transactional:
-- serialize to a temporary sibling, then atomically replace the stable save
-- path. Loading is persistence-only: the deserialized record is returned
-- unchanged, and validation/canonicalization belongs to FieldSave.restore on
-- resume and to FieldSave.validate on save.

local FieldSave = require("libs.engine.src.FieldSave")
local SaveFs = require("libs.storage.src.SaveFs")

local FieldSaveStore = {}
FieldSaveStore.__index = FieldSaveStore

local TEMP_PATH = FieldSave.PATH .. ".tmp"

---@class FieldSaveStore
---@field saveFs SaveFs
---@field opts table
---@field load fun(self: FieldSaveStore): table?, Errors.Error?
---@field save fun(self: FieldSaveStore, record: table): boolean
---@field reset fun(self: FieldSaveStore): boolean

---@param saveFs SaveFs
---@param opts table?
---@return FieldSaveStore
function FieldSaveStore.new(saveFs, opts)
  assert(getmetatable(saveFs) == SaveFs, "field save SaveFs required")
  local self = { saveFs = saveFs, opts = opts or {} }
  ---@cast self FieldSaveStore
  return setmetatable(self, FieldSaveStore)
end

-- Load is persistence-only: the deserialized record is returned exactly as
-- written (unknown keys included), and a storage/load error is returned
-- unchanged. FieldSave.restore is the single validation/canonicalization
-- boundary for deserialized records.
---@return table?, Errors.Error?
function FieldSaveStore:load()
  local record, loadErr = self.saveFs:loadLua(FieldSave.PATH)
  if not record then
    return nil, loadErr
  end
  return record
end

---@param record table
---@return boolean
function FieldSaveStore:save(record)
  local valid, validationErr = FieldSave.validate(record, self.opts)
  if not valid then
    error(validationErr)
  end
  self.saveFs:writeLua(TEMP_PATH, valid)
  self.saveFs:replace(TEMP_PATH, FieldSave.PATH)
  return true
end

---@return boolean
function FieldSaveStore:reset()
  self.saveFs:remove(TEMP_PATH)
  self.saveFs:remove(FieldSave.PATH)
  return true
end

return FieldSaveStore
