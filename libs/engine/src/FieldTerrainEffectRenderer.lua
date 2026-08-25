-- Adapts normalized terrain-effect models to the field world draw-item
-- contract. Simulation owns anchors and ages; this adapter owns GPU-backed
-- model preparation and converts global anchors into the current local frame.

local FieldEntranceIndicatorRenderer = require("libs.engine.src.FieldEntranceIndicatorRenderer")

local Renderer = {}
Renderer.__index = Renderer

function Renderer.new(assets, pool)
  assert(type(assets) == "table" and type(assets.effects) == "table", "terrain effect assets are required")
  local renderers = {}
  for _, kind in ipairs({ "tall_grass", "very_tall_grass" }) do
    renderers[kind] = FieldEntranceIndicatorRenderer.new(assets.effects[kind].model, pool)
  end
  return setmetatable({ renderers = renderers }, Renderer)
end

function Renderer:drawItems(status, origin)
  local items = {}
  for _, instance in ipairs(status.instances) do
    local renderer = assert(self.renderers[instance.kind], "terrain renderer is missing " .. instance.kind)
    local rendered = renderer:drawItems({
      visible = true,
      fieldEffect = instance.kind,
      position = {
        x = instance.fieldX - origin.x + 0.5,
        y = instance.worldY,
        z = instance.fieldZ - origin.z + 0.5,
      },
      rotationDegrees = 0,
      scale = 1,
    })
    for _, item in ipairs(rendered) do
      items[#items + 1] = item
    end
  end
  return items
end

function Renderer:dispose()
  for _, renderer in pairs(self.renderers) do
    renderer:dispose()
  end
  self.renderers = nil
end

return Renderer
