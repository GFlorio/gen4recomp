-- NNS sound-math domain tests. The outer player table is the ARM9
-- SNDi_DecibelTable; the existing square-table tests remain the ARM7 inner
-- volume contract.

local Assert = require("tests.support.Assert")
local NnsSoundMath = require("libs.engine.src.audio.NnsSoundMath")

local T = {}

function T.outer_decibel_uses_the_distinct_arm9_table_anchors()
  Assert.equal(type(NnsSoundMath.decibel), "function", "outer ARM9 decibel mapping must be exposed")
  local expected = {
    [0] = -32768,
    [1] = -421,
    [2] = -361,
    [64] = -60,
    [126] = -1,
    [127] = 0,
  }
  for level, value in pairs(expected) do
    Assert.equal(NnsSoundMath.decibel(level), value, "ARM9 decibel anchor " .. level)
  end
  Assert.isFalse(NnsSoundMath.decibel(64) == NnsSoundMath.decibelSquare(64), "outer and inner tables are distinct")
end

function T.outer_decibel_rejects_levels_outside_the_integer_table_domain()
  Assert.throws(function()
    NnsSoundMath.decibel(-1)
  end)
  Assert.throws(function()
    NnsSoundMath.decibel(128)
  end)
  local nonIntegerLevel = 1.5
  Assert.throws(function()
    NnsSoundMath.decibel(nonIntegerLevel --[[@as integer]])
  end)
end

return { tests = T }
