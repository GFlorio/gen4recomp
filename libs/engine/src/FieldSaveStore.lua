-- Persists validated field saves through a version-scoped CacheFs. Publication
-- is transactional: serialize to a temporary sibling, then atomically replace
-- the stable save path.

local FieldSave = require("libs.engine.src.FieldSave")

local FieldSaveStore = {}
FieldSaveStore.__index = FieldSaveStore

local TEMP_PATH = FieldSave.PATH .. ".tmp"

function FieldSaveStore.new(cacheFs)
  assert(cacheFs and cacheFs.writeLua and cacheFs.replace, "field save CacheFs required")
  return setmetatable({ cacheFs = cacheFs }, FieldSaveStore)
end

function FieldSaveStore:load()
  local record, loadErr = self.cacheFs:loadLua(FieldSave.PATH)
  if not record then return nil, loadErr end
  return FieldSave.validate(record)
end

function FieldSaveStore:save(record)
  local valid, validationErr = FieldSave.validate(record)
  if not valid then error(validationErr) end
  self.cacheFs:writeLua(TEMP_PATH, valid)
  self.cacheFs:replace(TEMP_PATH, FieldSave.PATH)
  return true
end

function FieldSaveStore:reset()
  self.cacheFs:remove(TEMP_PATH)
  self.cacheFs:remove(FieldSave.PATH)
  return true
end

return FieldSaveStore
