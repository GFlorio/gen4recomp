-- Static field effects share one normalized world draw-item presentation.

local Assert = require("tests.support.Assert")
local Renderer = require("libs.hgss.src.presentation.FieldStaticEffectRenderer")

local T = { tests = {} }

local function model()
  return {
    materials = {
      {
        id = 0,
        name = "effect",
        texture = "effect.png",
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
      },
    },
    batches = {
      {
        geometry = "effect.mesh",
        material = 0,
        alphaClass = "cutout",
        cullMode = "back",
        polygonAlpha = 31,
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        lightMask = 15,
        fogEnabled = false,
      },
    },
  }
end

local function pool()
  return {
    build = function(_, fn)
      return fn()
    end,
    meshFor = function()
      return { mesh = {}, center = { 0, 0, 0 } }
    end,
    imageFor = function()
      return {}
    end,
  }
end

T.tests["uses_one_normalized_world_draw_contract_for_default_and_explicit_effects"] = function()
  local renderer = Renderer.new(model(), pool())
  local baseline = renderer:drawItems({
    visible = true,
    position = { x = 2, y = 0.5, z = 3 },
    rotationDegrees = 45,
    scale = 1.25,
  })
  local surf = renderer:drawItems({
    visible = true,
    position = { x = 2, y = 0.5, z = 3 },
    rotationDegrees = 45,
    scale = 1.25,
    fieldEffect = "surf_attachment",
  })

  Assert.equal(#baseline, 1)
  Assert.equal(#surf, 1)
  Assert.near(baseline[1].polygonAlpha, 1.0, 1e-9)
  Assert.equal(baseline[1].alphaClass, "cutout")
  Assert.isTrue(baseline[1].worldSpace)
  Assert.equal(baseline[1].fieldEffect, "warp_entrance")
  Assert.equal(surf[1].fieldEffect, "surf_attachment")
  Assert.deepEqual(surf[1].transform, baseline[1].transform)
  Assert.deepEqual(surf[1].modelNormal, baseline[1].modelNormal)
  Assert.equal(surf[1].mesh, baseline[1].mesh)
  Assert.equal(surf[1].material, baseline[1].material)
  Assert.equal(surf[1].polygonAlpha, baseline[1].polygonAlpha)
  Assert.isTrue(surf[1].worldSpace)
end

T.tests["skips invisible and incomplete positions"] = function()
  local renderer = Renderer.new(model(), pool())
  Assert.deepEqual(renderer:drawItems({ visible = false }), {})
  Assert.deepEqual(
    renderer:drawItems({
      visible = true,
      position = { x = 1, y = 2 },
      rotationDegrees = 0,
      scale = 1,
    }),
    {}
  )
end

return { tests = T.tests }
