-- Test-only backend wrapper that redirects every save-directory-relative
-- path through a remap function, so a scoped filesystem type built with its
-- normal production constructor can be confined to a per-test/per-boot
-- namespace. Test isolation belongs here, not in the production
-- constructors: production roots are structural, and tests that need a
-- different physical location wrap the real backend instead.

local RemapBackend = {}
RemapBackend.__index = RemapBackend

---@param base table backend to delegate to
---@param remap fun(path: string): string
function RemapBackend.new(base, remap)
  assert(type(remap) == "function", "remap function required")
  return setmetatable({
    write = function(_, path, data)
      return base:write(remap(path), data)
    end,
    read = function(_, path)
      return base:read(remap(path))
    end,
    getInfo = function(_, path)
      return base:getInfo(remap(path))
    end,
    createDirectory = function(_, path)
      return base:createDirectory(remap(path))
    end,
    remove = function(_, path)
      return base:remove(remap(path))
    end,
    replace = function(_, sourcePath, destinationPath)
      return base:replace(remap(sourcePath), remap(destinationPath))
    end,
    getDirectoryItems = function(_, path)
      return base:getDirectoryItems(remap(path))
    end,
  }, RemapBackend)
end

return RemapBackend
