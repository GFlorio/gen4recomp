-- Synthetic tests for the common Nitro container header. Uses NitroBuilder to
-- assemble a BTX0-like file and checks section discovery, bounds, and the
-- structured failures for bad magic/BOM/size.

local Assert = require("tests.support.Assert")
local NitroFile = require("libs.nds.src.nitro.g3d.NitroFile")
local NitroBuilder = require("tests.support.NitroBuilder")

local T = {}

local function throwsCode(code, fn)
  local file, err = fn()
  Assert.isNil(file, "expected decode failure")
  Assert.notNil(err)
  local errorValue = assert(err) --[[@as { code: string }]]
  Assert.equal(errorValue.code, code)
end

local function sampleFile()
  return NitroBuilder.file("BTX0", {
    { magic = "TEX0", body = string.rep("\1", 16) },
    { magic = "ZZZ0", body = string.rep("\2", 8) },
  })
end

function T.decodes_header_and_sections()
  local f = assert(NitroFile.decode(sampleFile(), "BTX0"))
  Assert.equal(f.magic, "BTX0")
  Assert.equal(f.bom, 0xFEFF)
  Assert.equal(f.fileSize, #sampleFile())
  Assert.equal(#f.sections, 2)
  Assert.equal(f.sections[1].magic, "TEX0")
  Assert.equal(f.sections[1].size, 8 + 16)
  Assert.equal(f.sections[2].magic, "ZZZ0")
  -- Section bytes include the 8-byte block header.
  Assert.equal(f.sections[1].bytes:sub(1, 4), "TEX0")
end

function T.section_lookup_by_magic()
  local f = assert(NitroFile.decode(sampleFile()))
  Assert.equal(NitroFile.section(f, "TEX0").index, 0)
  Assert.isNil(NitroFile.section(f, "NONE"))
end

function T.rejects_wrong_magic()
  throwsCode("NITRO_FILE_BAD_MAGIC", function()
    return NitroFile.decode(sampleFile(), "BMD0")
  end)
end

function T.rejects_bad_bom()
  local bytes = sampleFile()
  bytes = bytes:sub(1, 4) .. string.char(0, 0) .. bytes:sub(7)
  throwsCode("NITRO_FILE_BAD_BOM", function()
    return NitroFile.decode(bytes)
  end)
end

function T.rejects_size_mismatch()
  throwsCode("NITRO_FILE_BAD_SIZE", function()
    return NitroFile.decode(sampleFile() .. "trailing")
  end)
end

function T.rejects_too_small()
  throwsCode("NITRO_FILE_TOO_SMALL", function()
    return NitroFile.decode("BTX0")
  end)
end

return { tests = T }
