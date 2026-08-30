-- SBC command-stream decoding tests. Command lengths and option-bit forms are
-- taken from NitroSystem's g3d/src/sbc.c (NNSi_G3dFuncSbc_*, each of which
-- advances rs->c by the command's own length) and the NNS_G3D_SBCFLG_* /
-- NNS_G3D_SBCCMD_MASK definitions in g3d/binres/res_struct.h.
--
-- Every case appends MAT/SHP/RET after the command under test: a wrong operand
-- length desynchronizes the stream, so the trailing draw and the RET terminator
-- are the alignment assertion.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local Fixture = require("tests.support.NsbmdFixture")

local T = {}

local ch = string.char
local TAIL = ch(0x04, 0) .. ch(0x05, 0) .. ch(0x01) -- MAT 0, SHP 0, RET

local function decodeSbc(sbc)
  local file = assert(Nsbmd.decode(Fixture.buildWithSbc(sbc)))
  return file.models[1].sbc
end

local function names(sbc)
  local out = {}
  for _, c in ipairs(sbc.commands) do
    out[#out + 1] = c.name
  end
  return table.concat(out, " ")
end

-- Assert the stream stayed aligned: the trailing MAT/SHP/RET decoded as such and
-- produced exactly one draw of shape 0.
local function assertAligned(sbc, leading)
  Assert.equal(names(sbc), leading .. " MAT SHP RET")
  Assert.equal(#sbc.draws, 1)
  Assert.equal(sbc.draws[1].shapeIndex, 0)
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected " .. code .. " to be raised")
  Assert.isTrue(Errors.is(err), "expected a structured Errors value, got " .. tostring(err))
  local errorValue = assert(err) --[[@as Errors.Error]]
  Assert.equal(errorValue.code, code)
  return errorValue
end

-- ---- BB / BBY ----

-- BB is 2 bytes plus one byte per store/restore operand (sbc.c: `u32 cmdLen = 2`
-- in NNSi_G3dFuncSbc_BB, incremented for SBCFLG_001 and SBCFLG_010).
function T.decodes_bb_without_operands()
  local sbc = decodeSbc(ch(0x07, 3) .. TAIL)
  assertAligned(sbc, "BB")
  local bb = sbc.commands[1]
  Assert.equal(bb.nodeIndex, 3)
  Assert.isNil(bb.storeSlot)
  Assert.isNil(bb.restoreSlot)
end

function T.decodes_bb_with_store_slot()
  local sbc = decodeSbc(ch(0x27, 3, 9) .. TAIL) -- opt 001
  assertAligned(sbc, "BB")
  Assert.equal(sbc.commands[1].nodeIndex, 3)
  Assert.equal(sbc.commands[1].storeSlot, 9)
  Assert.isNil(sbc.commands[1].restoreSlot)
end

function T.decodes_bb_with_restore_slot()
  local sbc = decodeSbc(ch(0x47, 3, 11) .. TAIL) -- opt 010
  assertAligned(sbc, "BB")
  Assert.isNil(sbc.commands[1].storeSlot)
  Assert.equal(sbc.commands[1].restoreSlot, 11)
end

-- With both operands the store precedes the restore: sbc.c reads the restore
-- index at rs->c + 2 for SBCFLG_010 but at rs->c + 3 for SBCFLG_011.
function T.decodes_bb_with_store_and_restore()
  local sbc = decodeSbc(ch(0x67, 3, 9, 11) .. TAIL) -- opt 011
  assertAligned(sbc, "BB")
  Assert.equal(sbc.commands[1].storeSlot, 9)
  Assert.equal(sbc.commands[1].restoreSlot, 11)
end

function T.decodes_bby_with_store_and_restore()
  local sbc = decodeSbc(ch(0x68, 4, 2, 5) .. TAIL) -- opt 011
  assertAligned(sbc, "BBY")
  Assert.equal(sbc.commands[1].nodeIndex, 4)
  Assert.equal(sbc.commands[1].storeSlot, 2)
  Assert.equal(sbc.commands[1].restoreSlot, 5)
end

-- ---- NODEDESC ----

function T.decodes_nodedesc_with_store_and_restore()
  local sbc = decodeSbc(ch(0x66, 0, 0, 0, 7, 8) .. TAIL) -- opt 011
  assertAligned(sbc, "NODEDESC")
  Assert.equal(sbc.commands[1].storeSlot, 7)
  Assert.equal(sbc.commands[1].restoreSlot, 8)
end

-- Byte 3 is not reserved: it carries the Maya single-scale-compensate flags
-- (NNS_G3D_SBC_NODEDESC_FLAG_MAYASSC_APPLY/_PARENT). The decoder must surface it.
function T.retains_nodedesc_flags_byte()
  local sbc = decodeSbc(ch(0x06, 1, 0, 0x03) .. TAIL)
  assertAligned(sbc, "NODEDESC")
  Assert.equal(sbc.commands[1].flags, 0x03)
end

-- ---- NODEMIX ----

-- NODEMIX is variable length: sbc.c advances by `3 + *(rs->c + 2) * 3`.
function T.decodes_nodemix_variable_length()
  local sbc = decodeSbc(ch(0x09, 6, 2, 1, 10, 128, 2, 11, 127) .. TAIL)
  assertAligned(sbc, "NODEMIX")
  local mix = sbc.commands[1]
  Assert.equal(mix.storeSlot, 6)
  Assert.equal(#mix.terms, 2)
  Assert.equal(mix.terms[1].matrixSlot, 1)
  Assert.equal(mix.terms[1].nodeIndex, 10)
  Assert.equal(mix.terms[1].ratio, 128)
  Assert.equal(mix.terms[2].matrixSlot, 2)
  Assert.equal(mix.terms[2].nodeIndex, 11)
  Assert.equal(mix.terms[2].ratio, 127)
end

function T.decodes_nodemix_with_no_terms()
  local sbc = decodeSbc(ch(0x09, 6, 0) .. TAIL)
  assertAligned(sbc, "NODEMIX")
  Assert.equal(#sbc.commands[1].terms, 0)
end

-- ---- CALLDL ----

-- CALLDL carries a u32 relative address and a u32 size: sbc.c advances by
-- `1 + sizeof(u32) + sizeof(u32)` = 9 bytes.
function T.decodes_calldl_as_nine_bytes()
  local sbc = decodeSbc(ch(0x0A, 0x10, 0, 0, 0, 0x20, 0, 0, 0) .. TAIL)
  assertAligned(sbc, "CALLDL")
  Assert.equal(sbc.commands[1].displayListOffset, 0x10)
  Assert.equal(sbc.commands[1].displayListSize, 0x20)
end

-- ---- option-bit validation ----

-- POSSCALE only accepts SBCFLG_000/001; sbc.c asserts exactly that.
function T.rejects_posscale_with_unsupported_option()
  local err = throwsCode("SBC_INVALID_OPTION_BITS", function()
    decodeSbc(ch(0x4B) .. TAIL) -- opt 010
  end)
  Assert.equal(err.context.optionBits, 0x40)
end

-- The option field is three bits wide (NNS_G3D_SBCFLG_MASK 0xE0), so 100..111
-- decode but have no meaning for the store/restore commands.
function T.rejects_nodedesc_with_high_option_bit()
  throwsCode("SBC_INVALID_OPTION_BITS", function()
    decodeSbc(ch(0x86, 0, 0, 0) .. TAIL) -- opt 100
  end)
end

function T.rejects_bb_with_high_option_bit()
  throwsCode("SBC_INVALID_OPTION_BITS", function()
    decodeSbc(ch(0x87, 0) .. TAIL) -- opt 100
  end)
end

function T.rejects_option_bits_on_commands_that_take_none()
  throwsCode("SBC_INVALID_OPTION_BITS", function()
    decodeSbc(ch(0x23, 0) .. TAIL) -- MTX with opt 001
  end)
end

-- ---- normalized command fields ----

function T.retains_offsets_and_raw_option_bits()
  local sbc = decodeSbc(ch(0x67, 3, 9, 11) .. ch(0x2B) .. TAIL)
  local bb, posscale = sbc.commands[1], sbc.commands[2]
  Assert.equal(bb.opcode, 0x07)
  Assert.equal(bb.command, 0x67)
  Assert.equal(bb.optionBits, 0x60)
  Assert.equal(bb.option, 3)
  Assert.equal(posscale.offset - bb.offset, 4)
  Assert.equal(posscale.opcode, 0x0B)
  Assert.equal(posscale.optionBits, 0x20)
  Assert.isTrue(posscale.inverse)
end

return { tests = T }
