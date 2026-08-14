-- Pure Lua reference for the DS GPU3D depth representation: the 24-bit
-- integer depth domain both Z-buffer and W-buffer modes are stored in, the
-- strict "in front" comparison the edge-marking predicate needs
-- (DsEdgeMarking), and the depth-equal tolerance a future depth-equal
-- integration needs. No love dependency, arithmetic only.
--
-- Authoritative source: GBATEK "3D Display - Depth Buffering" / "Polygon
-- Attributes - Depth-Test". The DS geometry engine can compare depth in
-- either mode, but both store the comparable value in the same 24-bit
-- unsigned domain (0..0xFFFFFF): Z-buffer mode derives it from the
-- perspective-divided clip z, W-buffer mode stores the (linear) clip w
-- directly. HGSS field rendering uses W-buffer mode (see shaders/edge.glsl's
-- header: linear depth is required to resolve short-object silhouettes at
-- the field's near/far range), so wbufferDepth is the conversion this
-- module's own callers are expected to exercise; zbufferDepth-shaped callers
-- would use quantize() directly on their own perspective-divided fraction.
--
-- The depth-equal tolerance (+/-0x200 in this 24-bit domain, GBATEK "Depth
-- Test / Depth Equal Comparision") is carried here as EQUAL_TOLERANCE so a
-- future depth-equal shader integration (Story 8's workstream) has one
-- authoritative source for the constant; this module does not itself decide
-- whether HGSS field content exercises depth-equal draws -- that is the
-- corpus census's job.
--
-- Scope: depth representation math only. Edge-predicate neighbor iteration
-- lives in DsEdgeMarking; translucent depth-write policy lives in DsBlend.

local DsDepth = {}

-- The 24-bit unsigned depth-value domain shared by both Z-buffer and
-- W-buffer storage.
DsDepth.MAX_DEPTH = 0xFFFFFF

-- GBATEK's documented depth-equal tolerance, in the 24-bit domain above.
DsDepth.EQUAL_TOLERANCE = 0x200

-- Normalized 0..1 depth fraction -> the 24-bit integer depth domain, clamped
-- to the representable range and truncated (not rounded), matching every
-- other DS fixed-point quantization step.
function DsDepth.quantize(fraction)
  local clamped = fraction < 0 and 0 or (fraction > 1 and 1 or fraction)
  return math.floor(clamped * DsDepth.MAX_DEPTH)
end

-- W-buffer depth for a linear eye-space distance `w` against the frustum's
-- effective far value `wMax` (the same normalize-then-quantize step
-- zbufferDepth-shaped callers would apply to a perspective-divided z).
function DsDepth.wbufferDepth(w, wMax)
  assert(wMax > 0, "wbufferDepth requires a positive wMax")
  return DsDepth.quantize(w / wMax)
end

-- True when `a` is strictly closer to the camera than `b` -- smaller depth
-- value wins, and equal depths are never "in front" of each other. This is
-- the comparison the edge-marking predicate uses (DsEdgeMarking.isEdgePixel);
-- it is intentionally stricter than isEqual below.
function DsDepth.isInFront(a, b)
  return a < b
end

-- True when two 24-bit depth values fall within the hardware's depth-equal
-- tolerance of each other.
function DsDepth.isEqual(a, b)
  return math.abs(a - b) <= DsDepth.EQUAL_TOLERANCE
end

return DsDepth
