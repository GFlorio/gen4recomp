local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local OverlayTable = require("libs.rom.src.OverlayTable")

local T = {}

local function u32(v)
  return string.char(v % 256, math.floor(v / 256) % 256,
    math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- One 32-byte overlay-table entry with sensible defaults.
local function entry(o)
  return u32(o.overlayId or 0) .. u32(o.ramAddress or 0) .. u32(o.ramSize or 0)
    .. u32(o.bssSize or 0) .. u32(o.staticInitStart or 0) .. u32(o.staticInitEnd or 0)
    .. u32(o.fileId or 0) .. u32(o.flags or 0)
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.parses_entries_preserving_all_fields()
  local bytes = entry({ overlayId = 0, ramAddress = 0x2000000, ramSize = 16, bssSize = 4,
    staticInitStart = 0x2000010, staticInitEnd = 0x2000014, fileId = 3, flags = 0x0102 })
    .. entry({ overlayId = 1, fileId = 4 })
  local overlays = OverlayTable.parse(bytes, 10)
  Assert.equal(#overlays, 2)
  local e = overlays[1]
  Assert.equal(e.overlayId, 0)
  Assert.equal(e.ramAddress, 0x2000000)
  Assert.equal(e.ramSize, 16)
  Assert.equal(e.bssSize, 4)
  Assert.equal(e.staticInitStart, 0x2000010)
  Assert.equal(e.staticInitEnd, 0x2000014)
  Assert.equal(e.fileId, 3)
  Assert.equal(e.flags, 0x0102)
  Assert.equal(overlays[2].overlayId, 1)
  Assert.equal(overlays[2].fileId, 4)
end

function T.empty_table_yields_no_overlays()
  Assert.equal(#OverlayTable.parse("", 10), 0)
end

function T.rejects_size_not_multiple_of_32()
  throwsCode("OVERLAY_TABLE_SIZE_INVALID", function()
    OverlayTable.parse(entry({ overlayId = 0, fileId = 0 }):sub(1, 20), 10)
  end)
end

function T.rejects_file_id_outside_fat()
  throwsCode("OVERLAY_FILE_ID_OUT_OF_FAT", function()
    OverlayTable.parse(entry({ overlayId = 0, fileId = 10 }), 10)
  end)
end

function T.rejects_duplicate_overlay_id()
  throwsCode("OVERLAY_DUPLICATE_ID", function()
    OverlayTable.parse(entry({ overlayId = 5, fileId = 0 }) .. entry({ overlayId = 5, fileId = 1 }), 10)
  end)
end

function T.rejects_duplicate_file_id()
  throwsCode("OVERLAY_DUPLICATE_FILE_ID", function()
    OverlayTable.parse(entry({ overlayId = 0, fileId = 2 }) .. entry({ overlayId = 1, fileId = 2 }), 10)
  end)
end

return T
