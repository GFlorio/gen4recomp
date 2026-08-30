-- Covers the pure classification half of SbcInventory: which special SBC
-- commands and option variants a model uses, its scaling rule, the Maya
-- scale-compensate flag bytes on NODEDESC, and whether a shape drawn under a
-- billboard matrix restores its own matrix mid-display-list.

local Assert = require("tests.support.Assert")
local Nsbmd = require("libs.nds.src.nitro.g3d.Nsbmd")
local SbcInventory = require("romdump.src.digest.SbcInventory")
local Fixture = require("tests.support.NsbmdFixture")

local T = {}

local ch = string.char

local function inspect(sbc, opts)
  local file = assert(Nsbmd.decode(Fixture.buildWithSbc(sbc, opts)))
  return SbcInventory.inspectModel(file.models[1])
end

local NODEDESC = ch(0x06, 0, 0, 0)
local MAT_SHP = ch(0x04, 0) .. ch(0x05, 0)
local RET = ch(0x01)

function T.reports_a_plain_joint_model_as_plain()
  local entry = inspect(NODEDESC .. MAT_SHP .. RET)
  Assert.equal(entry.scalingRule, 0)
  Assert.equal(entry.scalingRuleName, "standard")
  Assert.equal(entry.commands["NODEDESC/0"], 1)
  Assert.equal(#entry.billboardShapes, 0)
  Assert.isTrue(SbcInventory.isPlain(entry))
end

function T.counts_billboard_commands_by_option_variant()
  local entry = inspect(ch(0x07, 0) .. ch(0x67, 0, 1, 2) .. ch(0x08, 0) .. MAT_SHP .. RET)
  Assert.equal(entry.commands["BB/0"], 1)
  Assert.equal(entry.commands["BB/3"], 1)
  Assert.equal(entry.commands["BBY/0"], 1)
  Assert.isFalse(SbcInventory.isPlain(entry))
end

function T.counts_nodemix_and_calldl()
  local entry = inspect(ch(0x09, 1, 0) .. ch(0x0A, 0, 0, 0, 0, 0, 0, 0, 0) .. MAT_SHP .. RET)
  Assert.equal(entry.commands["NODEMIX/0"], 1)
  Assert.equal(entry.commands["CALLDL/0"], 1)
  Assert.isFalse(SbcInventory.isPlain(entry))
end

-- NODEDESC byte 3 carries NNS_G3D_SBC_NODEDESC_FLAG_MAYASSC_APPLY/_PARENT, which
-- the Maya scaling rule reads; a nonzero byte means plain-joint evaluation is
-- not sufficient.
function T.reports_nonzero_nodedesc_flag_bytes()
  local entry = inspect(ch(0x06, 0, 0, 0x02) .. MAT_SHP .. RET)
  Assert.deepEqual(entry.nodedescFlagBytes, { 0x02 })
  Assert.isFalse(SbcInventory.isPlain(entry))
end

-- A shape submitted after BB inherits the billboard matrix.
function T.attributes_shapes_drawn_under_a_billboard()
  local entry = inspect(ch(0x07, 0) .. MAT_SHP .. RET)
  Assert.equal(#entry.billboardShapes, 1)
  Assert.equal(entry.billboardShapes[1].shapeIndex, 0)
  Assert.equal(entry.billboardShapes[1].shapeName, "shp0")
  -- The fixture's display list issues no MTX_RESTORE, so one billboard matrix
  -- covers the whole shape.
  Assert.isFalse(entry.billboardShapes[1].usesMatrixRestore)
end

-- NODEDESC and MTX both replace the current matrix, ending the billboard.
function T.stops_attributing_shapes_after_the_matrix_is_replaced()
  Assert.equal(#inspect(ch(0x07, 0) .. NODEDESC .. MAT_SHP .. RET).billboardShapes, 0)
  Assert.equal(#inspect(ch(0x07, 0) .. ch(0x03, 1) .. MAT_SHP .. RET).billboardShapes, 0)
end

function T.isPlain_rejects_a_non_standard_scaling_rule()
  local entry = inspect(NODEDESC .. MAT_SHP .. RET)
  entry.scalingRule, entry.scalingRuleName = 1, "maya"
  Assert.isFalse(SbcInventory.isPlain(entry))
end

function T.lines_are_deterministic_and_payload_free()
  local entry = inspect(ch(0x07, 0) .. MAT_SHP .. RET)
  entry.archive, entry.memberId = "land_data", 7
  local lines = SbcInventory.lines({ entries = { entry }, skipped = {} })
  Assert.deepEqual(lines, SbcInventory.lines({ entries = { entry }, skipped = {} }))
  local joined = table.concat(lines, "\n")
  Assert.isTrue(joined:find("sbc%-inventory\tmodels\t1") ~= nil, joined)
  Assert.isTrue(joined:find("command\tBB/0\t1") ~= nil, joined)
  Assert.isTrue(joined:find("land_data:7 m0") ~= nil, joined)
end

return { tests = T }
