-- Persists validated field saves through a version-scoped CacheFs. Publication
-- is transactional: serialize to a temporary sibling, then atomically replace
-- the stable save path. Loading and saving both use the one current schema.
-- The scripting-era schema is g4-field-save-v2 (FieldSave.SCHEMA_V2); v2
-- loads migrate a v1 save through FieldSave.migrateV1ToV2 so existing
-- sessions survive the schema change.

local FieldSave = require("libs.engine.src.FieldSave")

local FieldSaveStore = {}
FieldSaveStore.__index = FieldSaveStore

local TEMP_PATH = FieldSave.PATH .. ".tmp"
local TEMP_PATH_V2 = FieldSave.PATH_V2 .. ".tmp"

---@param cacheFs table
---@param opts table?
function FieldSaveStore.new(cacheFs, opts)
  assert(cacheFs and cacheFs.writeLua and cacheFs.replace, "field save CacheFs required")
  return setmetatable({ cacheFs = cacheFs, opts = opts or {} }, FieldSaveStore)
end

function FieldSaveStore:load()
  local record, loadErr = self.cacheFs:loadLua(FieldSave.PATH)
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
  self.cacheFs:writeLua(TEMP_PATH, valid)
  self.cacheFs:replace(TEMP_PATH, FieldSave.PATH)
  return true
end

-- Load the current v2 save, migrating a v1 save when no v2 record exists.
-- Returns the v2 record, or nil plus the load error when neither exists.
function FieldSaveStore:loadV2()
  local record, loadErr = self.cacheFs:loadLua(FieldSave.PATH_V2)
  if record then
    local valid, validationErr = FieldSave.validateV2(record, self.opts)
    if not valid then
      return nil, validationErr
    end
    return valid
  end
  local v1, v1Err = self:load()
  if not v1 then
    return nil, v1Err
  end
  return FieldSave.migrateV1ToV2(v1)
end

function FieldSaveStore:saveV2(record)
  local valid, validationErr = FieldSave.validateV2(record, self.opts)
  if not valid then
    error(validationErr)
  end
  self.cacheFs:writeLua(TEMP_PATH_V2, valid)
  self.cacheFs:replace(TEMP_PATH_V2, FieldSave.PATH_V2)
  return true
end

function FieldSaveStore:reset()
  self.cacheFs:remove(TEMP_PATH)
  self.cacheFs:remove(FieldSave.PATH)
  self.cacheFs:remove(TEMP_PATH_V2)
  self.cacheFs:remove(FieldSave.PATH_V2)
  return true
end

return FieldSaveStore
