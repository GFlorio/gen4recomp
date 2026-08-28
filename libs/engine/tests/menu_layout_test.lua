-- Pure menu-layout tests exercise deterministic geometry across display
-- topologies without involving rendering or physical input.

local Assert = require("tests.support.Assert")
local MenuLayout = require("libs.engine.src.MenuLayout")
local ScreenTopology = require("libs.engine.src.ScreenTopology")

local T = {}

---@class MenuLayoutTest.Spec : MenuLayout.Spec

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function topology(width, height, opts)
  opts = opts or {}
  return ScreenTopology.oneDisplay({
    id = opts.id or "main",
    rect = rect(0, 0, width, height),
    safeRect = opts.safeRect,
    role = opts.role or "world",
    touch = opts.touch == true,
    occupiedRegions = opts.occupiedRegions,
  })
end

local function menu(count, opts)
  opts = opts or {}
  local items = {}
  for index = 1, count do
    items[index] = { text = opts.text or "Choice" }
  end
  return {
    items = items,
    selectedIndex = opts.selectedIndex or 0,
    cancellable = opts.cancellable == true,
  }
end

local function resolve(spec)
  spec.uiScale = spec.uiScale or 1
  spec.measureText = spec.measureText or function(text)
    return #text * 8
  end
  return MenuLayout.resolve(spec --[[@as MenuLayoutTest.Spec]])
end

---@param outer ScreenTopology.Rectangle
---@param inner ScreenTopology.Rectangle
---@return boolean
local function contains(outer, inner)
  return inner.x >= outer.x
    and inner.y >= outer.y
    and inner.x + inner.width <= outer.x + outer.width
    and inner.y + inner.height <= outer.y + outer.height
end

local function overlaps(a, b)
  return a.x < b.x + b.width and b.x < a.x + a.width and a.y < b.y + b.height and b.y < a.y + a.height
end

function T.four_by_three_uses_a_source_anchored_floating_frame_inside_the_safe_region()
  local layout = resolve({
    topology = topology(256, 192),
    menu = menu(3),
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 2, y = 2 },
  })

  Assert.equal(layout.presentation, "floating")
  Assert.equal(layout.surface.id, "main")
  Assert.isTrue(contains(layout.surface.safeRect, layout.frame))
  Assert.notNil(layout.itemRects[0])
  Assert.notNil(layout.itemRects[2])
  Assert.isTrue(contains(layout.contentRect, layout.itemRects[0]))
  Assert.isTrue(contains(layout.scrollViewport, layout.itemRects[0]))

  local right = resolve({
    topology = topology(256, 192),
    menu = menu(3),
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 28, y = 2 },
  })
  Assert.isTrue(right.frame.x > layout.frame.x, "source x must influence floating placement")
end

function T.layout_carries_display_text_without_exposing_menu_item_metadata()
  local layout = resolve({
    topology = topology(256, 192),
    menu = {
      items = {
        { text = "Take", value = 10, vanillaMetadata = 0xFF },
        { label = "Leave", value = 20, metadata = { hidden = true } },
        { text = { text = "Continue" }, value = 30 },
      },
      selectedIndex = 0,
    },
  })

  Assert.equal(layout.itemCount, 3)
  Assert.deepEqual(layout.itemTexts, { [0] = "Take", [1] = "Leave", [2] = "Continue" })
end

function T.occupied_regions_are_avoided_before_floating_geometry_is_clamped()
  local dialogue = rect(0, 116, 256, 76)
  local layout = resolve({
    topology = topology(256, 192, { occupiedRegions = { dialogue } }),
    menu = menu(2),
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 17, y = 16 },
  })

  Assert.equal(layout.presentation, "floating")
  Assert.isFalse(overlaps(layout.frame, dialogue))
  Assert.isTrue(contains(layout.surface.safeRect, layout.frame))
end

function T.explicit_floating_keeps_the_source_anchor_when_occupied_regions_cover_every_candidate()
  local layout = resolve({
    topology = topology(256, 192),
    menu = menu(2),
    sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 0, y = 0 },
    placementPreference = { mode = "floating" },
    occupiedRegions = { rect(0, 0, 256, 192) },
  })

  Assert.equal(layout.presentation, "docked")
  Assert.isTrue(contains(layout.surface.safeRect, layout.frame))
end

function T.text_measurement_and_scale_determine_intrinsic_width()
  local layout = resolve({
    topology = topology(640, 480),
    menu = { items = { { text = "W" } }, selectedIndex = 0 },
    uiScale = 2,
    measureText = function(text)
      Assert.equal(text, "W")
      return 100
    end,
  })

  Assert.equal(layout.frame.width, 256)
end

function T.narrow_safe_regions_cap_the_menu_width()
  local layout = resolve({
    topology = topology(80, 100),
    menu = menu(1),
  })

  Assert.isTrue(contains(layout.surface.safeRect, layout.frame))
end

function T.portrait_touch_menu_docks_to_the_safe_bottom_with_touch_sized_rows_and_cancel()
  local safe = rect(0, 47, 390, 763)
  local layout = resolve({
    topology = topology(390, 844, {
      safeRect = safe,
      touch = true,
      occupiedRegions = { rect(0, 700, 120, 110), rect(270, 700, 120, 110) },
    }),
    menu = menu(8, { cancellable = true }),
  })

  Assert.equal(layout.presentation, "docked")
  Assert.isTrue(contains(safe, layout.frame))
  Assert.isTrue(layout.frame.y + layout.frame.height <= safe.y + safe.height)
  Assert.isTrue(layout.frame.y + layout.frame.height >= safe.y + safe.height - 4)
  Assert.notNil(layout.cancelRect)
  Assert.isTrue(contains(safe, layout.cancelRect))
  Assert.isTrue(layout.itemRects[0].height >= MenuLayout.minimumTouchTarget)
end

function T.large_menus_scroll_without_overflow_and_keep_the_selected_item_visible()
  local layout = resolve({
    topology = topology(844, 390, { touch = true }),
    menu = menu(24, { selectedIndex = 23 }),
  })

  Assert.notNil(layout.scrollViewport)
  Assert.isTrue(layout.scrollViewport.height < 24 * MenuLayout.minimumTouchTarget)
  Assert.equal(layout.selectedIndex, 23)
  Assert.isTrue(contains(layout.scrollViewport, layout.itemRects[23]))
  Assert.isTrue(contains(layout.surface.safeRect, layout.frame))
end

function T.wide_large_menus_auto_dock_and_dual_screen_menus_prefer_the_auxiliary_surface()
  local wide = resolve({
    topology = topology(2560, 1080),
    menu = menu(18),
  })
  Assert.equal(wide.presentation, "docked")
  Assert.equal(wide.surface.id, "main")
  Assert.isTrue(contains(wide.surface.safeRect, wide.frame))

  local dual = ScreenTopology.dualDisplay({
    id = "main",
    rect = rect(0, 0, 400, 240),
    role = "world",
    touch = false,
  }, {
    id = "secondary",
    rect = rect(412, 0, 400, 240),
    role = "auxiliary",
    touch = true,
  })
  local auxiliary = resolve({ topology = dual, menu = menu(3) })
  Assert.equal(auxiliary.surface.id, "secondary")
  Assert.equal(auxiliary.presentation, "docked")
end

function T.geometry_matrix_keeps_frames_safe_and_selected_rows_visible()
  local fixtures = {
    { width = 1280, height = 960, presentation = "floating" },
    { width = 1920, height = 1080, presentation = "floating" },
    { width = 1080, height = 1920, presentation = "docked" },
  }

  for _, fixture in ipairs(fixtures) do
    local layout = resolve({
      topology = topology(fixture.width, fixture.height),
      menu = menu(4, { selectedIndex = 2 }),
      sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 12, y = 8 },
    })
    Assert.equal(layout.presentation, fixture.presentation)
    Assert.isTrue(contains(layout.surface.safeRect, layout.frame))
    Assert.isTrue(contains(layout.scrollViewport, layout.itemRects[2]))
    Assert.isTrue(layout.frame.width > 0 and layout.frame.height > 0)
  end
end

function T.directional_adjacency_follows_item_geometry_and_has_no_wraparound()
  local layout = {
    itemCount = 4,
    itemRects = {
      [0] = rect(0, 0, 8, 8),
      [1] = rect(12, 0, 8, 8),
      [2] = rect(0, 12, 8, 8),
      [3] = rect(12, 12, 8, 8),
    },
  }

  Assert.equal(MenuLayout.adjacentItem(layout, 0, "right"), 1)
  Assert.equal(MenuLayout.adjacentItem(layout, 0, "down"), 2)
  Assert.equal(MenuLayout.adjacentItem(layout, 3, "left"), 2)
  Assert.equal(MenuLayout.adjacentItem(layout, 3, "up"), 1)
  Assert.equal(MenuLayout.adjacentItem(layout, 0, "left"), nil)
  Assert.equal(MenuLayout.adjacentItem(layout, 0, "up"), nil)
  Assert.equal(MenuLayout.adjacentItem(layout, 3, "right"), nil)
  Assert.equal(MenuLayout.adjacentItem(layout, 3, "down"), nil)
end

function T.directional_adjacency_prefers_the_same_logical_row_or_column()
  local primaryAxisLayout = {
    itemCount = 3,
    itemRects = {
      [0] = rect(0, 0, 8, 8),
      [1] = rect(12, 24, 8, 8),
      [2] = rect(20, 0, 8, 8),
    },
  }
  Assert.equal(MenuLayout.adjacentItem(primaryAxisLayout, 0, "right"), 2)

  local crossAxisLayout = {
    itemCount = 3,
    itemRects = {
      [0] = rect(0, 0, 8, 8),
      [1] = rect(12, 24, 8, 8),
      [2] = rect(12, 12, 8, 8),
    },
  }
  Assert.equal(MenuLayout.adjacentItem(crossAxisLayout, 0, "right"), 2)
end

function T.rejects_malformed_menu_and_placement_input()
  Assert.throws(function()
    resolve({ topology = topology(256, 192), menu = menu(0) })
  end)
  Assert.throws(function()
    resolve({ topology = topology(256, 192), menu = menu(1), placementPreference = { mode = "popup" } })
  end)
  Assert.throws(function()
    resolve({ topology = topology(80, 10), menu = menu(1) })
  end)
  Assert.throws(function()
    resolve({
      topology = topology(256, 192),
      menu = menu(1),
      sourcePlacement = { system = "hgss_bottom_screen_tiles", x = 31, y = 0 },
    })
  end)
end

return { tests = T }
