local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local NitroFs = require("libs.rom.src.NitroFs")
local W = require("tests.support.FntWriter")

local u16 = W.u16
local T = {}

-- Assemble a raw FNT from explicit directory records for negative tests.
-- Each dir: { firstFileId=, field=, entries="..." }. field is dirCount for the
-- root record, parent directory id for children.
local function rawFnt(dirs)
  local main, subs = {}, {}
  local off = 8 * #dirs
  for i, d in ipairs(dirs) do
    main[i] = W.u32(off) .. u16(d.firstFileId) .. u16(d.field)
    subs[i] = d.entries
    off = off + #d.entries
  end
  return table.concat(main) .. table.concat(subs)
end

local function fileEntry(name)
  return string.char(#name) .. name
end
local function dirEntry(name, childId)
  return string.char(0x80 + #name) .. name .. u16(childId)
end
local ENDB = "\0"

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, code)
end

local NESTED = {
  files = { "root.bin" },
  dirs = {
    { name = "folder", files = { "a.bin" }, dirs = {
      { name = "nested", files = { "b.bin" } },
    } },
  },
}

function T.parses_nested_tree_with_zero_based_ids()
  local fs = NitroFs.parse(W.encode(NESTED, 0), 100)
  Assert.equal(fs.namedFileCount, 3)
  Assert.equal(fs.byFileId[0], "root.bin")
  Assert.equal(fs.byFileId[1], "folder/a.bin")
  Assert.equal(fs.byFileId[2], "folder/nested/b.bin")
  Assert.equal(fs.byPath["folder/nested/b.bin"], 2)
end

function T.honors_directory_record_first_file_id()
  local fs = NitroFs.parse(W.encode(NESTED, 5), 100)
  Assert.equal(fs.byFileId[5], "root.bin")
  Assert.equal(fs.byFileId[6], "folder/a.bin")
  Assert.equal(fs.byFileId[7], "folder/nested/b.bin")
  Assert.isNil(fs.byFileId[0])
end

-- A subdirectory entry preceding a file must not consume a file id.
function T.directory_entry_does_not_increment_file_id()
  local bytes = rawFnt({
    { firstFileId = 0, field = 2, entries = dirEntry("d", 0xF001) .. fileEntry("f.bin") .. ENDB },
    { firstFileId = 1, field = 0xF000, entries = fileEntry("g.bin") .. ENDB },
  })
  local fs = NitroFs.parse(bytes, 100)
  Assert.equal(fs.byFileId[0], "f.bin")
  Assert.equal(fs.byFileId[1], "d/g.bin")
end

function T.rejects_invalid_directory_count()
  throwsCode("FNT_DIR_COUNT_INVALID", function()
    NitroFs.parse(rawFnt({ { firstFileId = 0, field = 0, entries = ENDB } }), 100)
  end)
  throwsCode("FNT_DIR_COUNT_INVALID", function()
    NitroFs.parse(rawFnt({ { firstFileId = 0, field = 5000, entries = ENDB } }), 100)
  end)
end

function T.rejects_duplicate_path()
  throwsCode("FNT_DUPLICATE_PATH", function()
    NitroFs.parse(
      rawFnt({
        { firstFileId = 0, field = 1, entries = fileEntry("x.bin") .. fileEntry("x.bin") .. ENDB },
      }),
      100
    )
  end)
end

function T.rejects_duplicate_file_id()
  throwsCode("FNT_DUPLICATE_FILE_ID", function()
    NitroFs.parse(
      rawFnt({
        { firstFileId = 0, field = 2, entries = fileEntry("r.bin") .. dirEntry("a", 0xF001) .. ENDB },
        { firstFileId = 0, field = 0xF000, entries = fileEntry("g.bin") .. ENDB },
      }),
      100
    )
  end)
end

function T.rejects_recursive_cycle()
  throwsCode("FNT_DIRECTORY_CYCLE", function()
    NitroFs.parse(
      rawFnt({
        { firstFileId = 0, field = 2, entries = dirEntry("a", 0xF001) .. ENDB },
        { firstFileId = 0, field = 0xF000, entries = dirEntry("self", 0xF001) .. ENDB },
      }),
      100
    )
  end)
end

function T.rejects_path_traversal_and_separators()
  throwsCode("FNT_INVALID_NAME", function()
    NitroFs.parse(rawFnt({ { firstFileId = 0, field = 1, entries = fileEntry("..") .. ENDB } }), 100)
  end)
  throwsCode("FNT_INVALID_NAME", function()
    NitroFs.parse(rawFnt({ { firstFileId = 0, field = 1, entries = fileEntry("a/b") .. ENDB } }), 100)
  end)
  throwsCode("FNT_INVALID_NAME", function()
    NitroFs.parse(rawFnt({ { firstFileId = 0, field = 1, entries = fileEntry("a\\b") .. ENDB } }), 100)
  end)
end

function T.rejects_named_file_id_outside_fat()
  throwsCode("FNT_FILE_ID_OUT_OF_FAT", function()
    NitroFs.parse(rawFnt({ { firstFileId = 0, field = 1, entries = fileEntry("x.bin") .. ENDB } }), 0)
  end)
end

return T
