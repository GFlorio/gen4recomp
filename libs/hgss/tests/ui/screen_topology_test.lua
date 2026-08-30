-- ScreenTopology fixtures define presentation surfaces without choosing menu geometry.

local Assert = require("tests.support.Assert")
local ScreenTopology = require("libs.hgss.src.ui.ScreenTopology")

local T = {}

local function rectangle(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

function T.one_display_preserves_four_by_three_wide_and_portrait_surfaces()
  local fixtures = {
    { name = "fourByThree", width = 256, height = 192 },
    { name = "wide", width = 1920, height = 1080 },
    { name = "portrait", width = 1080, height = 1920 },
  }

  for _, fixture in ipairs(fixtures) do
    local topology = ScreenTopology.oneDisplay({
      id = fixture.name,
      rect = rectangle(0, 0, fixture.width, fixture.height),
      role = "world",
      touch = false,
    })
    Assert.equal(#topology.surfaces, 1)
    Assert.deepEqual(topology.surfaces[1].rect, rectangle(0, 0, fixture.width, fixture.height))
    Assert.deepEqual(topology.surfaces[1].safeRect, rectangle(0, 0, fixture.width, fixture.height))
    Assert.equal(topology.surfaces[1].role, "world")
    Assert.isFalse(topology.surfaces[1].touch)
    Assert.deepEqual(topology.surfaces[1].occupiedRegions, {})
  end
end

function T.phone_safe_area_and_occupied_regions_are_retained_without_layout_policy()
  local topology = ScreenTopology.oneDisplay({
    id = "phone",
    rect = rectangle(0, 0, 390, 844),
    safeRect = rectangle(0, 47, 390, 763),
    role = "world",
    touch = true,
    occupiedRegions = {
      rectangle(0, 700, 120, 110),
      rectangle(270, 700, 120, 110),
    },
  })

  local surface = topology.surfaces[1]
  Assert.deepEqual(surface.safeRect, rectangle(0, 47, 390, 763))
  Assert.deepEqual(surface.occupiedRegions, {
    rectangle(0, 700, 120, 110),
    rectangle(270, 700, 120, 110),
  })
  Assert.isTrue(surface.touch)
end

function T.dual_display_keeps_world_and_touch_capable_auxiliary_surfaces()
  local topology = ScreenTopology.dualDisplay({
    id = "main",
    rect = rectangle(0, 0, 400, 240),
    role = "world",
    touch = false,
  }, {
    id = "secondary",
    rect = rectangle(412, 0, 400, 240),
    safeRect = rectangle(420, 8, 384, 224),
    role = "auxiliary",
    touch = true,
    occupiedRegions = { rectangle(420, 184, 384, 48) },
  })

  Assert.equal(#topology.surfaces, 2)
  Assert.equal(topology.surfaces[1].role, "world")
  Assert.isFalse(topology.surfaces[1].touch)
  Assert.equal(topology.surfaces[2].role, "auxiliary")
  Assert.isTrue(topology.surfaces[2].touch)
  Assert.deepEqual(topology.surfaces[2].safeRect, rectangle(420, 8, 384, 224))
  Assert.deepEqual(topology.surfaces[2].occupiedRegions, { rectangle(420, 184, 384, 48) })
end

function T.rejects_missing_or_invalid_surface_data()
  Assert.throws(function()
    ScreenTopology.oneDisplay({ id = "main", rect = rectangle(0, 0, 256, 192), role = "world" } --[[@as any]])
  end)
  Assert.throws(function()
    ScreenTopology.oneDisplay({ id = "main", rect = rectangle(0, 0, 256, 192), role = "unknown", touch = false } --[[@as any]])
  end)
  Assert.throws(function()
    ScreenTopology.oneDisplay({
      id = "main",
      rect = rectangle(0, 0, 256, 192),
      safeRect = rectangle(-1, 0, 256, 192),
      role = "world",
      touch = false,
    })
  end)
  Assert.throws(function()
    ScreenTopology.new({
      surfaces = {
        { id = "main", rect = rectangle(0, 0, 256, 192), role = "world", touch = false },
        { id = "main", rect = rectangle(0, 200, 256, 192), role = "auxiliary", touch = true },
      },
    })
  end)
  Assert.throws(function()
    ScreenTopology.dualDisplay(
      { id = "main", rect = rectangle(0, 0, 256, 192), role = "auxiliary", touch = false },
      { id = "secondary", rect = rectangle(0, 200, 256, 192), role = "world", touch = true }
    )
  end)
  Assert.throws(function()
    ScreenTopology.oneDisplay({
      id = "main",
      rect = rectangle(0, 0, 256, 192),
      role = "world",
      touch = false,
      safeRect = false,
    } --[[@as any]])
  end)
  Assert.throws(function()
    ScreenTopology.oneDisplay({
      id = "main",
      rect = rectangle(0, 0, 256, 192),
      role = "world",
      touch = false,
      occupiedRegions = false,
    } --[[@as any]])
  end)
  Assert.throws(function()
    ScreenTopology.new({
      surfaces = {
        [1] = { id = "main", rect = rectangle(0, 0, 256, 192), role = "world", touch = false },
        [3] = { id = "secondary", rect = rectangle(0, 200, 256, 192), role = "auxiliary", touch = true },
      },
    })
  end)
end

function T.copies_surface_geometry_and_occupied_regions()
  local source = {
    id = "main",
    rect = rectangle(0, 0, 256, 192),
    safeRect = rectangle(0, 8, 256, 176),
    role = "world",
    touch = false,
    occupiedRegions = { rectangle(0, 136, 256, 48) },
  }

  local topology = ScreenTopology.oneDisplay(source)
  source.rect.width = 1
  source.safeRect.y = 1
  source.occupiedRegions[1].height = 1

  Assert.deepEqual(topology.surfaces[1].rect, rectangle(0, 0, 256, 192))
  Assert.deepEqual(topology.surfaces[1].safeRect, rectangle(0, 8, 256, 176))
  Assert.deepEqual(topology.surfaces[1].occupiedRegions, { rectangle(0, 136, 256, 48) })
end

function T.one_display_creates_one_surface()
  local topology = ScreenTopology.oneDisplay({
    id = "main",
    rect = rectangle(0, 0, 256, 192),
    role = "world",
    touch = false,
  })

  Assert.equal(#topology.surfaces, 1)
end

return { tests = T }
