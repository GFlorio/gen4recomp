local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Cartridge = require("libs.nds.src.rom.Cartridge")
local NdsBuilder = require("tests.support.NdsBuilder")

local T = {}

local FIXTURE = {
  gameCode = "IPKE",
  title = "TESTHG",
  overlays9 = { "OVERLAY0-DATA" },
  unmapped = { "UNMAPPED-DATA" },
  tree = {
    files = { { name = "root.bin", content = "ROOT" } },
    dirs = {
      {
        name = "folder",
        files = { { name = "a.bin", content = "AAAA" } },
        dirs = {
          { name = "nested", files = { { name = "b.bin", content = "BB" } } },
        },
      },
    },
  },
}

local function borrowedSource(data)
  return {
    size = function()
      return #data
    end,
    read = function(_, offset, length)
      if offset < 0 or length < 0 or offset + length > #data then
        return nil, "read outside fixture"
      end
      return data:sub(offset + 1, offset + length)
    end,
  }
end

local function u32At(data, offset)
  local b1, b2, b3, b4 = data:byte(offset + 1, offset + 4)
  return b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
end

local function withU32(data, offset, value)
  local bytes = string.char(
    value % 0x100,
    math.floor(value / 0x100) % 0x100,
    math.floor(value / 0x10000) % 0x100,
    math.floor(value / 0x1000000) % 0x100
  )
  return data:sub(1, offset) .. bytes .. data:sub(offset + 5)
end

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected an Errors object, got " .. tostring(err))
  Assert.equal(err.code, code)
end

function T.parses_generic_container_from_a_borrowed_source()
  local data = NdsBuilder.build(FIXTURE)
  local cartridge = Cartridge.parse(borrowedSource(data))
  Assert.equal(cartridge:header().gameCode, "IPKE")
  Assert.equal(cartridge:fatCount(), 5)
  Assert.equal(cartridge:readFatFile(0), "OVERLAY0-DATA")
  Assert.equal(cartridge:nitroFs().byPath["folder/nested/b.bin"], 4)
  Assert.equal(cartridge:arm9Overlays()[1].fileId, 0)
  Assert.equal(#cartridge:arm7Overlays(), 0)
end

function T.rejects_section_outside_rom()
  local data = NdsBuilder.build({ corrupt = { sectionOutOfRange = true } })
  throwsCode("NDS_SECTION_OUT_OF_RANGE", function()
    Cartridge.parse(borrowedSource(data))
  end)
end

function T.rejects_invalid_fat_size()
  local data = NdsBuilder.build({
    gameCode = FIXTURE.gameCode,
    title = FIXTURE.title,
    overlays9 = FIXTURE.overlays9,
    unmapped = FIXTURE.unmapped,
    tree = FIXTURE.tree,
    corrupt = { fatNotDiv8 = true },
  })
  throwsCode("NDS_FAT_SIZE_INVALID", function()
    Cartridge.parse(borrowedSource(data))
  end)
end

function T.rejects_fat_entry_with_start_past_end()
  local data = NdsBuilder.build(FIXTURE)
  local fatOffset = u32At(data, 0x48)
  local malformed = withU32(data, fatOffset, u32At(data, fatOffset + 4) + 1)
  throwsCode("FAT_ENTRY_INVALID", function()
    Cartridge.parse(borrowedSource(malformed))
  end)
end

function T.rejects_fat_entry_past_rom()
  local data = NdsBuilder.build(FIXTURE)
  local fatOffset = u32At(data, 0x48)
  local malformed = withU32(data, fatOffset + 4, #data + 1)
  throwsCode("FAT_RANGE_OUT_OF_BOUNDS", function()
    Cartridge.parse(borrowedSource(malformed))
  end)
end

return { tests = T }
