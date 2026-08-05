-- Synthetic tests for the generic Nitro resource dictionary. Verifies exact
-- name/index/data recovery in order, absolute data offsets, self-describing
-- sizeUnit, decoding at a nonzero base, and duplicate-name rejection.

local Assert = require("tests.support.Assert")
local NitroDict = require("libs.assets.src.nitro.NitroDict")
local NitroBuilder = require("tests.support.NitroBuilder")

local T = {}

local function sample()
  return NitroBuilder.dict({
    { name = "alpha", data = NitroBuilder.u32(0x11) },
    { name = "beta", data = NitroBuilder.u32(0x22) },
    { name = "gamma", data = NitroBuilder.u32(0x33) },
  })
end

function T.decodes_entries_in_order()
  local d = assert(NitroDict.decode(sample()))
  Assert.equal(d.count, 3)
  Assert.equal(d.sizeUnit, 4)
  Assert.equal(d.entries[1].name, "alpha")
  Assert.equal(d.entries[1].index, 0)
  Assert.equal(d.entries[3].name, "gamma")
  Assert.equal(d.entries[3].index, 2)
  Assert.equal(d.byName["beta"].index, 1)
end

function T.data_offset_is_absolute_and_correct()
  local bytes = sample()
  local d = assert(NitroDict.decode(bytes))
  local e = d.byName["gamma"]
  -- byte 0 of gamma's data unit is 0x33.
  Assert.equal(string.byte(bytes, e.dataOffset + 1), 0x33)
  Assert.equal(e.data, NitroBuilder.u32(0x33))
end

function T.decodes_at_nonzero_base()
  local prefix = string.rep("\0", 12)
  local d = assert(NitroDict.decode(prefix .. sample(), #prefix))
  Assert.equal(d.count, 3)
  Assert.equal(d.byName["alpha"].data, NitroBuilder.u32(0x11))
end

function T.rejects_duplicate_names()
  local bytes = NitroBuilder.dict({
    { name = "dup", data = NitroBuilder.u16(1) },
    { name = "dup", data = NitroBuilder.u16(2) },
  })
  local d, err = NitroDict.decode(bytes)
  Assert.isNil(d)
  Assert.equal(err.code, "NITRO_DICT_DUPLICATE_NAME")
end

return T
