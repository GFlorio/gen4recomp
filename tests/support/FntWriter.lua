-- Test helper: encode a directory tree into a valid NDS FNT byte string.
-- Tree node shape: { files = { name | {name=, content=}, ... },
--                    dirs = { { name = "d", files=, dirs= } } }
-- File IDs are assigned per-directory in directory-id (DFS preorder) order,
-- starting at baseFileId. Returns the FNT bytes and a byFileId map so callers
-- (NdsBuilder) place payloads under the exact ids the FNT encodes. Malformed
-- FNTs for negative tests are hand-crafted in the test itself, not here.

local FntWriter = {}

local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function nameOf(f) return type(f) == "table" and f.name or f end

function FntWriter.encode(tree, baseFileId)
  baseFileId = baseFileId or 0

  -- Collect directories in DFS preorder; assign ids from 0xF000 and full paths.
  local dirs = {}
  local function collect(node, parentId, parentPath)
    local id = 0xF000 + #dirs
    node._id = id
    dirs[#dirs + 1] = { node = node, id = id, parentId = parentId, path = parentPath }
    for _, sub in ipairs(node.dirs or {}) do
      collect(sub, id, parentPath .. sub.name .. "/")
    end
  end
  collect(tree, 0xF000, "")

  -- File ids: consecutive per directory, in directory order.
  local counter = baseFileId
  local byFileId = {}
  for _, d in ipairs(dirs) do
    d.firstFileId = counter
    for _, f in ipairs(d.node.files or {}) do
      byFileId[counter] = d.path .. nameOf(f)
      counter = counter + 1
    end
  end

  -- Subtable bytes and their offsets (relative to FNT start).
  local mainTableSize = 8 * #dirs
  local offset = mainTableSize
  local subtables = {}
  for i, d in ipairs(dirs) do
    local parts = {}
    for _, f in ipairs(d.node.files or {}) do
      local name = nameOf(f)
      parts[#parts + 1] = string.char(#name) .. name
    end
    for _, sub in ipairs(d.node.dirs or {}) do
      parts[#parts + 1] = string.char(0x80 + #sub.name) .. sub.name .. u16(sub._id)
    end
    parts[#parts + 1] = "\0"
    local bytes = table.concat(parts)
    d.subtableOffset = offset
    subtables[i] = bytes
    offset = offset + #bytes
  end

  -- Main table: one 8-byte record per directory.
  local main = {}
  for i, d in ipairs(dirs) do
    local field = (i == 1) and #dirs or d.parentId
    main[i] = u32(d.subtableOffset) .. u16(d.firstFileId) .. u16(field)
  end

  return table.concat(main) .. table.concat(subtables), byFileId
end

FntWriter.u16 = u16
FntWriter.u32 = u32

return FntWriter
