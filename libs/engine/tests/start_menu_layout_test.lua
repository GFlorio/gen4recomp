-- Responsive Start Menu placement: the canonical 256x192 surface is mapped
-- through ScreenTopology as one whole surface — dual-screen auxiliary,
-- landscape/ultrawide side panel, single 4:3 overlay, portrait lower panel,
-- safe areas — with the internal geometry invariant. The tests pin the
-- placement record shape ({ surfaceId, frame, scale, logicalWidth,
-- logicalHeight }), uniform-scale/center/deterministic-rounding invariants,
-- and the pointer transform (reject outside frame, map host to canonical
-- 0..255 x 0..191) over the one record shared by hit testing and rendering.

local Assert = require("tests.support.Assert")
local FieldUiFixture = require("tests.support.FieldUiFixture")
local ScreenTopology = require("libs.engine.src.ScreenTopology")
local StartMenuLayout = require("libs.engine.src.StartMenuLayout")

local T = {}

local function rect(x, y, width, height)
  return { x = x, y = y, width = width, height = height }
end

local function display(id, width, height, opts)
  opts = opts or {}
  return {
    id = id,
    rect = opts.rect or rect(0, 0, width, height),
    safeRect = opts.safeRect,
    role = opts.role or "world",
    touch = opts.touch == true,
  }
end

local function oneDisplay(width, height, opts)
  return ScreenTopology.oneDisplay(display(opts and opts.id or "main", width, height, opts))
end

-- The placement record exactly per the layout contract: the chosen surface
-- id, the integer host-space frame, the uniform scale, and the fixed logical
-- dimensions. No extra keys, so hit testing and rendering share one record.
function T.placement_record_has_exactly_the_pinned_shape()
  local record = StartMenuLayout.resolve(oneDisplay(256, 192))
  Assert.deepEqual(record, {
    surfaceId = "main",
    frame = { x = 0, y = 0, width = 256, height = 192 },
    scale = 1,
    logicalWidth = 256,
    logicalHeight = 192,
  })
end

-- The responsive matrix: every topology row pins its exact record plus the
-- uniform-scale/inside-safe/integer-frame invariants.
function T.responsive_matrix_places_every_topology_as_a_whole_surface()
  local dual = ScreenTopology.dualDisplay(display("world", 256, 192), display("aux", 256, 192, { role = "auxiliary" }))
  local matrix = {
    {
      name = "256x192 canonical",
      topology = oneDisplay(256, 192),
      expected = { surfaceId = "main", frame = { 0, 0, 256, 192 }, scale = 1 },
    },
    {
      name = "1280x960 4:3",
      topology = oneDisplay(1280, 960),
      expected = { surfaceId = "main", frame = { 0, 0, 1280, 960 }, scale = 5 },
    },
    {
      name = "1920x1080 16:9",
      topology = oneDisplay(1920, 1080),
      expected = { surfaceId = "main", frame = { 1440, 360, 480, 360 }, scale = 1.875 },
    },
    {
      name = "2560x1080 ultrawide",
      topology = oneDisplay(2560, 1080),
      expected = { surfaceId = "main", frame = { 1440, 120, 1120, 840 }, scale = 4.375 },
    },
    {
      name = "1080x1920 portrait",
      topology = oneDisplay(1080, 1920),
      expected = { surfaceId = "main", frame = { 0, 1110, 1080, 810 }, scale = 4.21875 },
    },
    {
      name = "390x844 phone portrait",
      topology = oneDisplay(390, 844),
      expected = { surfaceId = "main", frame = { 0, 552, 390, 292 }, scale = 1.5234375 },
    },
    {
      name = "844x390 phone landscape",
      topology = oneDisplay(844, 390),
      expected = { surfaceId = "main", frame = { 520, 73, 324, 243 }, scale = 1.265625 },
    },
    {
      name = "dual 256x192-style surfaces",
      topology = dual,
      expected = { surfaceId = "aux", frame = { 0, 0, 256, 192 }, scale = 1 },
    },
  }
  for _, row in ipairs(matrix) do
    local record = StartMenuLayout.resolve(row.topology)
    Assert.deepEqual(record, {
      surfaceId = row.expected.surfaceId,
      frame = {
        x = row.expected.frame[1],
        y = row.expected.frame[2],
        width = row.expected.frame[3],
        height = row.expected.frame[4],
      },
      scale = row.expected.scale,
      logicalWidth = 256,
      logicalHeight = 192,
    }, row.name .. " placement record")
    local safe = StartMenuLayout.selectSurface(row.topology).safeRect
    local frame = record.frame
    Assert.isTrue(
      frame.x >= safe.x
        and frame.y >= safe.y
        and frame.x + frame.width <= safe.x + safe.width
        and frame.y + frame.height <= safe.y + safe.height,
      row.name .. " frame must stay inside the safe rectangle"
    )
    for _, value in ipairs({ frame.x, frame.y, frame.width, frame.height }) do
      Assert.equal(value, math.floor(value), row.name .. " frame must be integer at the host boundary")
    end
    Assert.near(frame.width / 256, record.scale, 1 / 256, row.name .. " horizontal scale")
    Assert.near(frame.height / 192, record.scale, 1 / 192, row.name .. " vertical scale")
    Assert.isTrue(record.scale > 0, row.name .. " scale must be positive")
  end
end

-- The dual-screen rule: the auxiliary display is the menu screen, and the
-- whole surface fills a 4:3 auxiliary at its own origin.
function T.dual_display_places_the_menu_on_the_auxiliary_surface()
  local auxiliary = display("bottom", 256, 192, { rect = rect(256, 240, 256, 192), role = "auxiliary" })
  local record = StartMenuLayout.resolve(ScreenTopology.dualDisplay(display("top", 256, 192), auxiliary))
  Assert.equal(record.surfaceId, "bottom")
  Assert.deepEqual(record.frame, { x = 256, y = 240, width = 256, height = 192 })

  local large = StartMenuLayout.resolve(
    ScreenTopology.dualDisplay(display("world", 256, 192), display("aux", 512, 384, { role = "auxiliary" }))
  )
  Assert.equal(large.surfaceId, "aux")
  Assert.deepEqual(large.frame, { x = 0, y = 0, width = 512, height = 384 })
  Assert.equal(large.scale, 2)
end

-- Wide landscape: the menu is a side panel right of the 4:3 world reference
-- frame, scaled to the available panel height, still 4:3 internally.
function T.wide_landscape_uses_a_side_panel_right_of_the_world_frame()
  local record = StartMenuLayout.resolve(oneDisplay(1920, 1080))
  Assert.deepEqual(record.frame, { x = 1440, y = 360, width = 480, height = 360 })
  Assert.equal(record.scale, 1.875)
  Assert.equal(record.frame.height / record.frame.width, 3 / 4, "the surface must stay 4:3 internally")
end

-- Ultrawide uses the same model: the menu never stretches across the unused
-- horizontal space.
function T.ultrawide_keeps_the_menu_panel_without_horizontal_stretch()
  local record = StartMenuLayout.resolve(oneDisplay(2560, 1080))
  Assert.deepEqual(record.frame, { x = 1440, y = 120, width = 1120, height = 840 })
  Assert.isTrue(record.frame.width < 2560, "the menu must not stretch across the host width")
  Assert.equal(record.frame.height / record.frame.width, 3 / 4)
end

-- A side panel wide enough for the full height: the scale binds to the panel
-- height and the menu is centered in the panel.
function T.side_panel_scales_to_the_available_height_when_the_panel_is_tall()
  local record = StartMenuLayout.resolve(oneDisplay(4000, 1080))
  Assert.equal(record.scale, 5.625)
  Assert.deepEqual(record.frame, { x = 2000, y = 0, width = 1440, height = 1080 })
  Assert.equal(record.frame.height, 1080, "the menu scales to the available panel height")
end

-- Single 4:3 host: the surface is a modal overlay that fills the host.
function T.single_four_by_three_host_is_a_full_surface_overlay()
  local record = StartMenuLayout.resolve(oneDisplay(1280, 960))
  Assert.deepEqual(record.frame, { x = 0, y = 0, width = 1280, height = 960 })
  Assert.equal(record.scale, 5)
end

-- Portrait partitions vertically: the world stays above and the menu becomes
-- a full-width lower panel.
function T.portrait_partitions_vertically_into_a_lower_panel()
  local record = StartMenuLayout.resolve(oneDisplay(1080, 1920))
  Assert.deepEqual(record.frame, { x = 0, y = 1110, width = 1080, height = 810 })
  Assert.equal(
    record.frame.y + record.frame.height,
    1920,
    "the lower panel must sit at the bottom of the safe rectangle"
  )
end

-- The portrait partition is subject to minimum usable sizes: when the world
-- region or the panel would become unusable, the layout falls back to the
-- centered uniform fit so the whole surface is still placed inside bounds.
function T.portrait_partition_falls_back_when_a_region_is_too_small()
  local record = StartMenuLayout.resolve(oneDisplay(390, 370))
  Assert.deepEqual(record.frame, { x = 0, y = 39, width = 390, height = 292 })
  Assert.equal(record.scale, 1.5234375)

  local tiny = StartMenuLayout.resolve(oneDisplay(100, 300))
  Assert.deepEqual(tiny.frame, { x = 0, y = 112, width = 100, height = 75 })
  Assert.equal(tiny.scale, 0.390625)
end

-- Safe areas: the whole canonical surface is scaled and placed inside the
-- safe rectangle, never reflowed around the occupied space.
function T.safe_areas_keep_the_whole_surface_inside_the_safe_rectangle()
  local offset = oneDisplay(1920, 1080, { safeRect = rect(100, 100, 1600, 900) })
  local record = StartMenuLayout.resolve(offset)
  Assert.deepEqual(record.frame, { x = 1300, y = 400, width = 400, height = 300 })
  Assert.equal(record.scale, 1.5625)
  local safe = offset.surfaces[1].safeRect
  Assert.isTrue(
    record.frame.x >= safe.x
      and record.frame.y >= safe.y
      and record.frame.x + record.frame.width <= safe.x + safe.width
      and record.frame.y + record.frame.height <= safe.y + safe.height,
    "the frame must stay inside the safe rectangle"
  )

  local fractional = oneDisplay(1920, 1080, { safeRect = rect(0, 80, 1920, 920) })
  local fractionalRecord = StartMenuLayout.resolve(fractional)
  Assert.deepEqual(fractionalRecord.frame, { x = 1226, y = 280, width = 693, height = 520 })
end

-- Deterministic pixel rounding at the host-space boundary: odd host sizes
-- floor to integer frames, and repeated resolution returns the same record.
function T.placement_is_deterministic_and_rounds_at_the_host_boundary()
  local odd = oneDisplay(999, 800)
  local first = StartMenuLayout.resolve(odd)
  local second = StartMenuLayout.resolve(odd)
  Assert.deepEqual(first, second)
  Assert.deepEqual(first.frame, { x = 0, y = 25, width = 999, height = 749 })
  Assert.equal(first.scale, 999 / 256)
end

-- A landscape host too narrow for a usable side panel falls back to the
-- centered overlay instead of shrinking the menu next to the world frame.
function T.narrow_side_panels_fall_back_to_the_centered_overlay()
  local record = StartMenuLayout.resolve(oneDisplay(1280, 900))
  Assert.deepEqual(record.frame, { x = 40, y = 0, width = 1200, height = 900 })
  Assert.equal(record.scale, 4.6875)
end

-- Surface selection follows the sibling MenuLayout shape: auxiliary first,
-- else the first surface.
function T.selection_prefers_the_auxiliary_surface_and_falls_back_to_the_first()
  local three = ScreenTopology.new({
    surfaces = {
      display("world-a", 256, 192),
      display("world-b", 256, 192),
      display("bottom", 256, 192, { role = "auxiliary" }),
    },
  })
  Assert.equal(StartMenuLayout.selectSurface(three).id, "bottom")
  Assert.equal(StartMenuLayout.resolve(three).surfaceId, "bottom")

  local worlds = ScreenTopology.new({ surfaces = { display("world-a", 256, 192), display("world-b", 256, 192) } })
  Assert.equal(StartMenuLayout.selectSurface(worlds).id, "world-a")
  Assert.equal(StartMenuLayout.resolve(worlds).surfaceId, "world-a")
end

-- The pointer transform: hit testing rejects every point outside the frame,
-- then maps inside points back to canonical 0..255 x 0..191 logical space.
function T.host_to_logical_rejects_outside_the_frame_and_maps_inside_points()
  local record = StartMenuLayout.resolve(oneDisplay(1920, 1080))
  local outside = {
    { 100, 100 },
    { 1500, 100 },
    { 1500, 1000 },
    { 2000, 500 },
    { 1440, 359 },
    { 1439, 360 },
    { 1920, 720 },
    { 1440, 720 },
  }
  for _, point in ipairs(outside) do
    Assert.isNil(StartMenuLayout.hostToLogical(record, point[1], point[2]), "points outside the frame must be rejected")
  end
  local canonicalX, canonicalY = StartMenuLayout.hostToLogical(record, 1680, 540)
  Assert.equal(canonicalX, 128)
  Assert.equal(canonicalY, 96)
end

-- One record shared by hit testing and rendering: the renderer draws the
-- canonical surface at frame origin under uniform scale, and hostToLogical is
-- the exact inverse of that placement — slot rects live only in canonical
-- space and are never scaled into a second set of host rectangles.
function T.hit_testing_and_rendering_share_one_record_with_an_exact_round_trip()
  local record = StartMenuLayout.resolve(oneDisplay(1920, 1080))
  local points = {}
  for slotId = 1, 10 do
    local slot = FieldUiFixture.START_MENU_SLOTS[slotId]
    points[#points + 1] = { slot.x, slot.y }
    points[#points + 1] = { slot.x + slot.width - 1, slot.y + slot.height - 1 }
  end
  points[#points + 1] = { 0, 0 }
  points[#points + 1] = { 255, 191 }
  for _, point in ipairs(points) do
    local hostX = record.frame.x + point[1] * record.scale
    local hostY = record.frame.y + point[2] * record.scale
    local canonicalX, canonicalY = StartMenuLayout.hostToLogical(record, hostX, hostY)
    Assert.notNil(canonicalX, "a rendered canonical point must hit-test inside the frame")
    Assert.notNil(canonicalY, "a rendered canonical point must hit-test inside the frame")
    Assert.equal(canonicalX, point[1])
    Assert.equal(canonicalY, point[2])
  end
end

-- The rendered surface spans exactly the frame: the canonical edge maps to
-- the frame's far corner, which the transform rejects (the half-open frame).
function T.the_canonical_edge_maps_to_the_rejected_frame_boundary()
  local record = StartMenuLayout.resolve(oneDisplay(1920, 1080))
  local cornerX = record.frame.x + 256 * record.scale
  local cornerY = record.frame.y + 192 * record.scale
  Assert.near(cornerX, record.frame.x + record.frame.width, 1e-9)
  Assert.near(cornerY, record.frame.y + record.frame.height, 1e-9)
  Assert.isNil(StartMenuLayout.hostToLogical(record, cornerX, cornerY), "the frame's far edge is outside the surface")
end

-- Programming invariants: a malformed topology or placement record is a
-- fault, never a guessed default.
function T.rejects_malformed_inputs()
  local nothing = nil ---@type any
  Assert.throws(function()
    StartMenuLayout.resolve(nothing)
  end, "resolve requires a topology")
  Assert.throws(function()
    StartMenuLayout.resolve({ surfaces = {} })
  end, "resolve requires at least one surface")
  Assert.throws(function()
    StartMenuLayout.resolve(oneDisplay(100, 100, { safeRect = rect(0.5, 0, 100, 100) }))
  end, "fractional safe rectangles are unsupported")
  Assert.throws(function()
    StartMenuLayout.selectSurface(nothing)
  end, "selectSurface requires a topology")
  local notARecord = {} ---@type any
  Assert.throws(function()
    StartMenuLayout.hostToLogical(notARecord, 10, 10)
  end, "hostToLogical requires a placement record")
  local text = "10" ---@type any
  Assert.throws(function()
    StartMenuLayout.hostToLogical(StartMenuLayout.resolve(oneDisplay(1920, 1080)), text, 10)
  end, "host coordinates must be numbers")
end

return { tests = T }
