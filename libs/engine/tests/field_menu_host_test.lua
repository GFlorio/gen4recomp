-- FieldMenuHost forwards script menu presentation preferences to layout.

local Assert = require("tests.support.Assert")
local FieldInput = require("libs.engine.src.FieldInput")
local FieldMenuHost = require("libs.engine.src.FieldMenuHost")
local ScreenTopology = require("libs.engine.src.ScreenTopology")

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

function T.uses_the_supplied_auxiliary_surface_for_automatic_menus()
  local host = FieldMenuHost.new({
    width = 1280,
    height = 720,
    input = FieldInput.new(),
    screenTopology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 960, height = 720 }, touch = false, role = "world" },
      { id = "auxiliary", rect = { x = 960, y = 0, width = 320, height = 720 }, touch = true, role = "auxiliary" }
    ),
  })
  host:sync({
    menuDefinition = {
      items = { { text = { text = "Take" }, value = 10 } },
      cancellable = false,
    },
    selectedIndex = 0,
  }, 100)

  local layout = host:presentation().layout
  Assert.equal(layout.surface.id, "auxiliary")
  Assert.equal(layout.presentation, "docked")
end

function T.keeps_the_supplied_topology_when_the_host_resizes()
  local host = FieldMenuHost.new({
    width = 1280,
    height = 720,
    input = FieldInput.new(),
    screenTopology = ScreenTopology.dualDisplay(
      { id = "main", rect = { x = 0, y = 0, width = 960, height = 720 }, touch = false, role = "world" },
      { id = "auxiliary", rect = { x = 960, y = 0, width = 320, height = 720 }, touch = true, role = "auxiliary" }
    ),
  })
  host:resize(1920, 1080)
  host:sync({
    menuDefinition = {
      items = { { text = { text = "Take" }, value = 10 } },
      cancellable = false,
    },
    selectedIndex = 0,
  }, 100)

  Assert.equal(host:presentation().layout.surface.id, "auxiliary")
end

function T.routes_the_touch_cancel_affordance_to_the_menu()
  local host = FieldMenuHost.new({ width = 256, height = 192, input = FieldInput.new() })
  host:sync({
    menuDefinition = {
      items = { { text = { text = "Take" }, value = 10 } },
      cancellable = true,
    },
    selectedIndex = 0,
  }, 100)

  local cancel = assert(host:presentation().layout.cancelRect)
  local events = host:inputEvents({
    {
      type = "pointer_down",
      x = cancel.x + cancel.width / 2,
      y = cancel.y + cancel.height / 2,
    },
  })

  Assert.equal(events[1].type, "cancel")
end

function T.horizontal_navigation_does_not_change_focus_in_a_relaid_out_single_column_menu()
  local host = FieldMenuHost.new({ width = 256, height = 192, input = FieldInput.new() })
  local state = {
    menuDefinition = {
      items = { { text = "First", value = 1 }, { text = "Second", value = 2 } },
      cancellable = false,
    },
    selectedIndex = 1,
  }
  host:sync(state, 100)
  host:resize(390, 844)

  Assert.deepEqual(host:inputEvents({ { type = "navigate", direction = "left" } }), {})
  Assert.equal(host:presentation().selectedIndex, 1)
  Assert.deepEqual(host:inputEvents({ { type = "navigate", direction = "right" } }), {})
  Assert.equal(host:presentation().selectedIndex, 1)
end

function T.batched_navigation_uses_each_layout_resolved_focus_target_in_order()
  local host = FieldMenuHost.new({ width = 256, height = 192, input = FieldInput.new() })
  host:sync({
    menuDefinition = {
      items = { { text = "First", value = 1 }, { text = "Second", value = 2 }, { text = "Third", value = 3 } },
      cancellable = false,
    },
    selectedIndex = 0,
  }, 100)

  Assert.deepEqual(
    host:inputEvents({
      { type = "navigate", direction = "down" },
      { type = "navigate", direction = "down" },
    }),
    {
      { type = "focus", itemIndex = 1 },
      { type = "focus", itemIndex = 2 },
    }
  )
end

return T
