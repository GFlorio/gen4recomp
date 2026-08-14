-- Pure Lua reference for the DS GPU3D translucent blend/depth contract: the
-- RGB blend equation, the destination-alpha result, same-polygon-ID
-- self-blend rejection, and the opaque/translucent depth-write interaction.
-- No love dependency, arithmetic only.
--
-- Authoritative source: GBATEK "3D Display - Alpha Blending" / "Polygon
-- Attributes". Source RGB/alpha here are already in DsFragment's native
-- domains (6-bit RGB 0-63, 5-bit alpha 0-31) -- DsFragment owns the
-- combiner's source-alpha quantization (MODULATE/DECAL); this module never
-- re-derives it, only consumes it.
--
-- Blend equation (5-bit alpha scale even though RGB is 6-bit, truncating
-- divide):
--   Dst' = (Src*SrcAlpha + Dst*(31-SrcAlpha)) / 31
-- Destination alpha keeps the strongest alpha seen at that pixel:
--   DstAlpha' = max(SrcAlpha, DstAlpha)
-- A translucent polygon is not blended against a pixel already carrying the
-- same polygon ID from a previous translucent write at that pixel (GBATEK:
-- avoids a polygon self-blending across its own overlapping/concave
-- triangles); the fragment is otherwise processed normally (depth-write
-- policy still applies). Opaque fragments always write depth; translucent
-- fragments write depth only when the polygon's translucent-depth-write
-- attribute is set.

local DsBlend = {}

-- Translucent RGB blend, 6-bit domain, 5-bit alpha scale.
function DsBlend.blendRgb6(srcRgb6, srcAlpha5, dstRgb6)
  local out = {}
  for i = 1, 3 do
    out[i] = math.floor((srcRgb6[i] * srcAlpha5 + dstRgb6[i] * (31 - srcAlpha5)) / 31)
  end
  return out
end

-- Resulting destination alpha: the strongest of source and prior destination.
function DsBlend.blendAlpha5(srcAlpha5, dstAlpha5)
  return math.max(srcAlpha5, dstAlpha5)
end

-- True when a translucent fragment must be rejected (left unblended) because
-- its polygon ID matches the last translucent polygon ID written at this
-- pixel. No prior translucent write (nil) never rejects.
function DsBlend.rejectsSelfBlend(polygonId, lastTranslucentPolygonId)
  return lastTranslucentPolygonId ~= nil and polygonId == lastTranslucentPolygonId
end

-- Depth-write policy: opaque fragments (including wireframe, which draws in
-- opaque mode) always write depth; translucent fragments write depth only
-- when the polygon's translucent-depth-write attribute is enabled.
function DsBlend.shouldWriteDepth(isOpaque, translucentDepthWriteEnabled)
  if isOpaque then
    return true
  end
  return translucentDepthWriteEnabled == true
end

-- Composes the rules above for one fragment.
-- params: srcRgb6, srcAlpha5, polygonId, isOpaque, translucentDepthWriteEnabled,
--         dstRgb6, dstAlpha5, lastTranslucentPolygonId (nil if none yet).
-- Returns { rgb6, alpha5, writeDepth, translucentPolygonId } where
-- translucentPolygonId is the polygon ID to carry forward as the pixel's
-- last-translucent-write state (nil for an opaque fragment).
function DsBlend.resolveFragment(params)
  if params.isOpaque then
    return {
      rgb6 = { params.srcRgb6[1], params.srcRgb6[2], params.srcRgb6[3] },
      alpha5 = params.srcAlpha5,
      writeDepth = true,
      translucentPolygonId = nil,
    }
  end

  local writeDepth = DsBlend.shouldWriteDepth(false, params.translucentDepthWriteEnabled)
  if DsBlend.rejectsSelfBlend(params.polygonId, params.lastTranslucentPolygonId) then
    return {
      rgb6 = { params.dstRgb6[1], params.dstRgb6[2], params.dstRgb6[3] },
      alpha5 = params.dstAlpha5,
      writeDepth = writeDepth,
      translucentPolygonId = params.polygonId,
    }
  end

  return {
    rgb6 = DsBlend.blendRgb6(params.srcRgb6, params.srcAlpha5, params.dstRgb6),
    alpha5 = DsBlend.blendAlpha5(params.srcAlpha5, params.dstAlpha5),
    writeDepth = writeDepth,
    translucentPolygonId = params.polygonId,
  }
end

return DsBlend
