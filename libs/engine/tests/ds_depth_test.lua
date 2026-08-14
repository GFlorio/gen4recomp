-- Tests for the DS depth-representation reference: quantization into the
-- 24-bit integer depth domain, W-buffer vs Z-buffer conversion, and the
-- strict-front / depth-equal comparisons that later edge-marking and
-- depth-equal integration work will consume.

local Assert = require("tests.support.Assert")
local DsDepth = require("libs.engine.src.DsDepth")

local T = {}

function T.max_depth_is_24bit()
  Assert.equal(DsDepth.MAX_DEPTH, 0xFFFFFF)
end

function T.quantize_clamps_to_24bit_range()
  Assert.equal(DsDepth.quantize(0), 0)
  Assert.equal(DsDepth.quantize(1), 0xFFFFFF)
  Assert.equal(DsDepth.quantize(-0.5), 0)
  Assert.equal(DsDepth.quantize(1.5), 0xFFFFFF)
end

function T.quantize_truncates_not_rounds()
  -- Halfway plus a hair below the next integer step must truncate down, not
  -- round to the nearest representable depth: the hardware truncates its
  -- fixed-point accumulator everywhere else, and depth quantization follows
  -- the same rule.
  local halfStep = 0.5 / DsDepth.MAX_DEPTH
  local justBelowOne = 1 - halfStep * 0.5
  Assert.equal(DsDepth.quantize(justBelowOne), DsDepth.MAX_DEPTH - 1)
end

function T.quantize_exhaustive_boundary_and_midpoint_fractions()
  local fractions = { 0, 0.1, 0.25, 0.5, 0.75, 0.9, 1 }
  for _, f in ipairs(fractions) do
    local expected = math.floor(f * DsDepth.MAX_DEPTH)
    Assert.equal(DsDepth.quantize(f), expected, "f=" .. f)
  end
end

function T.is_in_front_strict_smaller_depth_wins()
  Assert.isTrue(DsDepth.isInFront(100, 200))
  Assert.isFalse(DsDepth.isInFront(200, 100))
end

function T.is_in_front_equal_depth_is_not_in_front()
  -- Strict comparison: equal depths never count as "in front" for the edge
  -- predicate, regardless of the depth-equal tolerance below.
  Assert.isFalse(DsDepth.isInFront(150, 150))
end

function T.is_equal_within_tolerance_boundaries()
  local tol = DsDepth.EQUAL_TOLERANCE
  Assert.isTrue(DsDepth.isEqual(1000, 1000))
  Assert.isTrue(DsDepth.isEqual(1000, 1000 + tol))
  Assert.isTrue(DsDepth.isEqual(1000, 1000 - tol))
  Assert.isFalse(DsDepth.isEqual(1000, 1000 + tol + 1))
  Assert.isFalse(DsDepth.isEqual(1000, 1000 - tol - 1))
end

function T.is_equal_is_symmetric_exhaustive_near_tolerance()
  local tol = DsDepth.EQUAL_TOLERANCE
  for delta = -(tol + 2), tol + 2 do
    local expected = math.abs(delta) <= tol
    Assert.equal(DsDepth.isEqual(1000, 1000 + delta), expected, "delta=" .. delta)
    Assert.equal(DsDepth.isEqual(1000 + delta, 1000), expected, "delta=" .. delta)
  end
end

function T.wbuffer_depth_is_the_raw_linear_value_quantized()
  -- W-buffer mode stores clip-space w directly (linear eye-space distance),
  -- not a perspective-divided z; converting a normalized 0..1 fraction of the
  -- w range is the same quantize() used for Z-buffer mode, since both modes
  -- share the 24-bit storage domain -- only what feeds the fraction differs.
  Assert.equal(DsDepth.wbufferDepth(0, 100), 0)
  Assert.equal(DsDepth.wbufferDepth(100, 100), DsDepth.MAX_DEPTH)
  Assert.equal(DsDepth.wbufferDepth(50, 100), math.floor(0.5 * DsDepth.MAX_DEPTH))
end

function T.wbuffer_depth_requires_positive_wmax()
  Assert.throws(function()
    DsDepth.wbufferDepth(1, 0)
  end)
end

return { tests = T }
