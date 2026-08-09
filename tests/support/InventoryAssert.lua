-- Shared assertion over a MapAssetInspector featureInventory: the target's
-- material/polygon state must be finite and contain no feature the renderer does
-- not support. Target-agnostic on purpose -- both Elm and New Bark run it, so a
-- future map that introduces toon/shadow, a local light, or a shininess table
-- fails the private suite here instead of silently mis-rendering.

local Assert = require("tests.support.Assert")

local SUPPORTED_MODES = { modulation = true, decal = true }

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

local M = {}

function M.assertSupported(inv, label)
  Assert.isTrue(inv.modelCount >= 1 and inv.materialCount >= 1, label .. ": non-empty inventory")
  Assert.deepEqual(inv.itemTags, { 0 })

  for _, mode in ipairs(inv.polygonModes) do
    Assert.isTrue(SUPPORTED_MODES[mode], label .. ": unsupported polygon mode " .. tostring(mode))
  end
  for _, a in ipairs(inv.polygonAlphas) do
    Assert.isTrue(a >= 0 and a <= 31, label .. ": polygon alpha out of range " .. tostring(a))
  end
  for _, m in ipairs(inv.lightMasks) do
    Assert.isTrue(m >= 0 and m <= 15, label .. ": light mask out of range " .. tostring(m))
  end
  for _, id in ipairs(inv.polygonIds) do
    Assert.isTrue(id >= 0 and id <= 63, label .. ": polygon id out of range " .. tostring(id))
  end

  -- No shininess and no shape-local light/shininess overrides: these are the
  -- deferred features the compiler is allowed to reject rather than implement.
  Assert.equal(inv.useShininessTable, 0)
  Assert.isNil(inv.gxOpcodes.LIGHT_VECTOR, label .. ": local LIGHT_VECTOR present")
  Assert.isNil(inv.gxOpcodes.LIGHT_COLOR, label .. ": local LIGHT_COLOR present")
  Assert.isNil(inv.gxOpcodes.SHININESS, label .. ": local SHININESS present")

  -- Wrap/flip bits are fully material-owned (texImageParamMask 0xFFFFFFFF).
  Assert.isTrue(contains(inv.texImageParamMasks, "0xFFFFFFFF"), label .. ": expected a full texImageParamMask")
end

return M
