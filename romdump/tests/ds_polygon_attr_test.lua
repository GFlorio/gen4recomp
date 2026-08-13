-- Bitfield tests for DsPolygonAttr: every named POLYGON_ATTR field and every
-- front/back cull combination, plus a fully-packed word.

local Assert = require("tests.support.Assert")
local DsPolygonAttr = require("romdump.src.digest.nitro.DsPolygonAttr")

local T = {}

-- Assemble a POLYGON_ATTR word from named parts (arithmetic, no bit lib).
local function pack(f)
  return (f.lightMask or 0)
    + (f.mode or 0) * 2 ^ 4
    + (f.renderBack and 2 ^ 6 or 0)
    + (f.renderFront and 2 ^ 7 or 0)
    + (f.translucentDepthWrite and 2 ^ 11 or 0)
    + (f.farClip and 2 ^ 12 or 0)
    + (f.oneDot and 2 ^ 13 or 0)
    + (f.depthEqual and 2 ^ 14 or 0)
    + (f.fog and 2 ^ 15 or 0)
    + (f.alpha or 0) * 2 ^ 16
    + (f.polygonId or 0) * 2 ^ 24
end

function T.decodes_light_mask_mode_and_alpha()
  local a = DsPolygonAttr.decode(pack({ lightMask = 0xB, mode = 1, alpha = 31, polygonId = 63, renderFront = true }))
  Assert.equal(a.lightMask, 0xB)
  Assert.equal(a.polygonModeRaw, 1)
  Assert.equal(a.polygonMode, "decal")
  Assert.equal(a.polygonAlpha, 31)
  Assert.equal(a.polygonId, 63)
end

function T.decodes_all_polygon_modes()
  Assert.equal(DsPolygonAttr.decode(pack({ mode = 0, renderFront = true })).polygonMode, "modulation")
  Assert.equal(DsPolygonAttr.decode(pack({ mode = 1, renderFront = true })).polygonMode, "decal")
  Assert.equal(DsPolygonAttr.decode(pack({ mode = 2, renderFront = true })).polygonMode, "toon")
  Assert.equal(DsPolygonAttr.decode(pack({ mode = 3, renderFront = true })).polygonMode, "shadow")
end

function T.decodes_every_flag()
  local a = DsPolygonAttr.decode(pack({
    renderFront = true,
    translucentDepthWrite = true,
    farClip = true,
    oneDot = true,
    depthEqual = true,
    fog = true,
  }))
  Assert.isTrue(a.translucentDepthWrite)
  Assert.isTrue(a.farClipEnabled)
  Assert.isTrue(a.oneDotEnabled)
  Assert.isTrue(a.depthEqual)
  Assert.isTrue(a.fogEnabled)
end

function T.flags_default_false()
  local a = DsPolygonAttr.decode(pack({ renderFront = true }))
  Assert.isFalse(a.translucentDepthWrite)
  Assert.isFalse(a.farClipEnabled)
  Assert.isFalse(a.oneDotEnabled)
  Assert.isFalse(a.depthEqual)
  Assert.isFalse(a.fogEnabled)
end

function T.derives_cull_from_render_flags()
  Assert.equal(DsPolygonAttr.decode(pack({ renderFront = true })).cullMode, "back")
  Assert.equal(DsPolygonAttr.decode(pack({ renderBack = true })).cullMode, "front")
  Assert.equal(DsPolygonAttr.decode(pack({ renderFront = true, renderBack = true })).cullMode, "none")
  Assert.equal(DsPolygonAttr.decode(pack({})).cullMode, "all") -- neither -> skip
end

function T.rejects_non_32bit_word()
  Assert.throws(function()
    DsPolygonAttr.decode(-1)
  end)
  Assert.throws(function()
    DsPolygonAttr.decode(2 ^ 32)
  end)
end

return { tests = T }
