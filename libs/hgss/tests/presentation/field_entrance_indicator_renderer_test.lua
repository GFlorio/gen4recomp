local Assert = require("tests.support.Assert")
local Renderer = require("libs.hgss.src.presentation.FieldEntranceIndicatorRenderer")

local T = { tests = {} }

T.tests["normalizes polygon alpha for FieldRenderer draw items"] = function()
  local model = {
    materials = {
      {
        id = 0,
        name = "indicator",
        texture = "indicator.png",
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
      },
    },
    batches = {
      {
        geometry = "indicator.mesh",
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
  local pool = {
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
  local renderer = Renderer.new(model, pool)
  local items = renderer:drawItems({
    visible = true,
    position = { x = 0, y = 0, z = 0 },
    rotationDegrees = 0,
    scale = 1,
  })

  Assert.equal(#items, 1)
  Assert.near(items[1].polygonAlpha, 1.0, 1e-9)
  Assert.equal(items[1].alphaClass, "cutout", "the indicator keeps source transparency semantics")
  Assert.isTrue(items[1].worldSpace)
  Assert.equal(items[1].fieldEffect, "warp_entrance", "field effects opt into the shared depth-biased projection")
end

return T
