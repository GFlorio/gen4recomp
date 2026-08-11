-- FieldMenuHost forwards script menu presentation preferences to layout.

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldMenuHost = require("libs.engine.src.FieldMenuHost")

local T = {}

function T.applies_the_semantic_menu_placement_preference()
  local host = FieldMenuHost.new({ width = 256, height = 192, input = FieldInput.new() })
  host:sync({
    menuDefinition = {
      items = { { text = { text = "Take" }, value = 10 } },
      cancellable = false,
      placementPreference = { mode = "docked", anchor = "bottom", surface = "main" },
    },
    selectedIndex = 0,
  }, 100)

  Assert.equal(host:presentation().layout.presentation, "docked")
end

return T
