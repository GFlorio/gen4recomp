-- Builds headless field-effect model instances from validated dynamic assets.
-- The factory caches immutable definitions and creates independent animation
-- state for each terrain-effect emission; graphics composition may replace it
-- with a GPU-backed factory later.

local ModelDefinition = require("libs.hgss.src.presentation.ModelDefinition")
local ModelInstance = require("libs.hgss.src.presentation.ModelInstance")

local Factory = {}

function Factory.new()
  local definitions = {}
  local function create(kind, effect)
    local resource = definitions[kind]
    if not resource then
      resource = {
        definition = ModelDefinition.fromNitroDescriptor(effect.model, { key = "field-effect:" .. kind }),
      }
      definitions[kind] = resource
    end
    return ModelInstance.new(resource.definition)
  end
  return create
end

return Factory
