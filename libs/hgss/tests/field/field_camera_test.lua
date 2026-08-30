-- FieldCamera exact eye placement, projection selection, and delayed Y follow.

local Assert = require("tests.support.Assert")
local FieldCamera = require("libs.hgss.src.field.FieldCamera")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}
local function approx(a, b, tolerance)
  return math.abs(a - b) < (tolerance or 1e-6)
end
local function angleIndexToRadians(raw)
  return raw * 2 * math.pi / 65536
end

local function profile(overrides)
  local value = {
    projectionType = "perspective",
    distanceTiles = 10,
    angleXRaw = -8192,
    angleYRaw = 0,
    halfFovRadians = math.rad(15),
    fullVerticalFovRadians = math.rad(30),
    nearTiles = 1,
    farTiles = 100,
    targetOffsetTiles = { x = 1, y = 2, z = 3 },
  }
  for key, replacement in pairs(overrides or {}) do
    value[key] = replacement
  end
  return value
end

local function newBarkProfile()
  return profile({
    distanceTiles = 0x0029AEC1 / 65536,
    angleXRaw = 0xDD62 - 0x10000,
    halfFovRadians = angleIndexToRadians(0x05C1),
    fullVerticalFovRadians = angleIndexToRadians(0x05C1) * 2,
    nearTiles = 0x00096000 / 65536,
    farTiles = 0x004B0000 / 65536,
    targetOffsetTiles = { x = 0, y = 0, z = 0 },
  })
end

function T.eye_uses_raw_angles_distance_and_effective_target()
  local camera = FieldCamera.new(profile(), { initialTarget = { x = 4, y = 5, z = 6 } })
  Assert.isTrue(approx(camera.target.x, 5) and approx(camera.target.y, 7) and approx(camera.target.z, 9))
  Assert.isTrue(approx(camera.eye.x, 5))
  Assert.isTrue(approx(camera.eye.y, 7 + math.sqrt(50)))
  Assert.isTrue(approx(camera.eye.z, 9 + math.sqrt(50)))
end

function T.fixed_update_applies_xz_immediately_and_delays_y_after_priming()
  local camera = FieldCamera.new(profile({ targetOffsetTiles = { x = 0, y = 0, z = 0 } }), {
    initialTarget = { x = 0, y = 0, z = 0 },
  })
  for tick = 1, 7 do
    camera:updateFixed({ x = tick, y = tick, z = tick * 2 })
  end
  camera:updateFixed({ x = 8, y = 8, z = 16 })
  Assert.equal(camera.target.x, 8)
  Assert.equal(camera.target.z, 16)
  Assert.equal(camera.target.y, 8)
  camera:updateFixed({ x = 9, y = 10, z = 18 })
  Assert.equal(camera.target.y, 9)
end

function T.orthographic_projection_uses_distance_and_half_angle()
  local camera = FieldCamera.new(
    profile({
      projectionType = "orthographic",
      distanceTiles = 20,
      halfFovRadians = math.rad(30),
    }),
    { initialTarget = { x = 0, y = 0, z = 0 }, canonicalAspect = 4 / 3 }
  )
  local halfY = math.tan(math.rad(30)) * 20
  local projection = camera:projection()
  Assert.isTrue(approx(projection[1], 1 / (halfY * 4 / 3)))
  Assert.isTrue(approx(projection[6], 1 / halfY))
end

function T.perspective_projection_preserves_vertical_fov_when_aspect_changes()
  local camera = FieldCamera.new(profile(), { initialTarget = { x = 0, y = 0, z = 0 } })
  local canonical = camera:canonicalProjection()
  camera:setProjectionAspect(32 / 9)
  local wide = camera:projection()
  Assert.isTrue(approx(canonical[6], wide[6]), "vertical scale")
  Assert.isTrue(wide[1] < canonical[1], "wider horizontal extent")
end

function T.zoom_changes_projection_scale_without_moving_the_rom_camera()
  local camera = FieldCamera.new(profile(), { initialTarget = { x = 0, y = 0, z = 0 } })
  local eye = { x = camera.eye.x, y = camera.eye.y, z = camera.eye.z }
  local canonical = camera:projection()
  camera:setZoom(0.75)
  local zoomedOut = camera:projection()
  Assert.isTrue(approx(zoomedOut[1], canonical[1] * 0.75))
  Assert.isTrue(approx(zoomedOut[6], canonical[6] * 0.75))
  Assert.deepEqual(camera.eye, eye)
  Assert.throws(function()
    camera:setZoom(0)
  end)
end

function T.projection_caches_follow_aspect_and_zoom_invalidations()
  local camera = FieldCamera.new(profile(), { initialTarget = { x = 0, y = 0, z = 0 } })
  local projection = camera:projection()
  local billboard = camera:billboardProjection()
  Assert.equal(camera:projection(), projection, "unchanged projection inputs reuse the projection matrix")
  Assert.equal(
    camera:billboardProjection(),
    billboard,
    "unchanged projection inputs reuse the billboard projection matrix"
  )

  camera:setProjectionAspect(32 / 9)
  local wideProjection = camera:projection()
  local wideBillboard = camera:billboardProjection()
  Assert.isFalse(wideProjection == projection, "aspect changes replace the projection matrix")
  Assert.isFalse(wideBillboard == billboard, "aspect changes replace the billboard projection matrix")
  camera:setProjectionAspect(32 / 9)
  Assert.equal(camera:projection(), wideProjection, "repeating the current aspect does not invalidate projection")
  Assert.equal(
    camera:billboardProjection(),
    wideBillboard,
    "repeating the current aspect does not invalidate billboard projection"
  )

  camera:setZoom(0.75)
  local zoomedProjection = camera:projection()
  local zoomedBillboard = camera:billboardProjection()
  Assert.isFalse(zoomedProjection == wideProjection, "zoom changes replace the projection matrix")
  Assert.isFalse(zoomedBillboard == wideBillboard, "zoom changes replace the billboard projection matrix")
  camera:setZoom(0.75)
  Assert.equal(camera:projection(), zoomedProjection, "repeating the current zoom does not invalidate projection")
  Assert.equal(
    camera:billboardProjection(),
    zoomedBillboard,
    "repeating the current zoom does not invalidate billboard projection"
  )
end

function T.canonical_projection_ignores_runtime_aspect_and_zoom()
  local camera = FieldCamera.new(profile(), { initialTarget = { x = 0, y = 0, z = 0 } })
  local canonical = camera:canonicalProjection()
  camera:setProjectionAspect(32 / 9)
  camera:setZoom(0.5)
  Assert.deepEqual(camera:canonicalProjection(), canonical)
end

-- The billboard projection is the world projection with the Z-row translation
-- pulled toward the camera (see FieldCamera:billboardProjection).
function T.billboard_projection_bumps_only_the_z_translation()
  local prof = profile()
  local camera = FieldCamera.new(prof, { initialTarget = { x = 0, y = 0, z = 0 } })
  local normal = camera:projection()
  local billboard = camera:billboardProjection()
  local angleX = angleIndexToRadians(prof.angleXRaw)
  local expectedDelta = normal[11] * FieldCamera.FIELD_BILLBOARD_DEPTH_OFFSET_TILES * math.cos(angleX)
  Assert.near(billboard[15], normal[15] + expectedDelta, 1e-9, "the Z-row translation gains the depth pull")
  for i = 1, 16 do
    if i ~= 15 then
      Assert.near(billboard[i], normal[i], 1e-9, "element " .. i .. " is unchanged")
    end
  end
  Assert.deepEqual(camera:projection(), normal, "the camera's own projection is untouched")
end

function T.billboard_projection_pulls_toward_the_camera_for_field_pitches()
  local camera = FieldCamera.new(newBarkProfile(), { initialTarget = { x = 0, y = 0, z = 0 } })
  local normal = camera:projection()
  local billboard = camera:billboardProjection()
  Assert.isTrue(billboard[15] < normal[15], "the negative z-scale times a positive offset pulls the depth row down")
end

function T.billboard_projection_applies_to_orthographic_profiles_too()
  local prof = profile({
    projectionType = "orthographic",
    distanceTiles = 20,
    halfFovRadians = math.rad(30),
  })
  local camera = FieldCamera.new(prof, { initialTarget = { x = 0, y = 0, z = 0 }, canonicalAspect = 4 / 3 })
  local normal = camera:projection()
  local billboard = camera:billboardProjection()
  local angleX = angleIndexToRadians(prof.angleXRaw)
  Assert.near(
    billboard[15],
    normal[15] + normal[11] * FieldCamera.FIELD_BILLBOARD_DEPTH_OFFSET_TILES * math.cos(angleX),
    1e-9
  )
  Assert.near(billboard[12], normal[12], 1e-9, "the orthographic w row is untouched")
end

function T.history_can_be_disabled()
  local camera = FieldCamera.new(profile(), {
    initialTarget = { x = 0, y = 0, z = 0 },
    historyEnabled = false,
  })
  for tick = 1, 8 do
    camera:updateFixed({ x = 0, y = tick, z = 0 })
  end
  camera:updateFixed({ x = 0, y = 20, z = 0 })
  Assert.equal(camera.target.y, 22)
end

function T.view_interpolates_between_the_previous_and_current_states()
  local camera = FieldCamera.new(profile({ targetOffsetTiles = { x = 0, y = 0, z = 0 } }), {
    initialTarget = { x = 0, y = 0, z = 0 },
  })
  -- Before any fixed update, previous and current are the initial state, so
  -- every alpha renders the same view.
  local before = camera:view()
  Assert.deepEqual(camera:view(0), before, "alpha zero shows the previous state")
  Assert.deepEqual(camera:view(0.5), before, "no movement means nothing to interpolate")

  camera:updateFixed({ x = 0, y = 0, z = 10 })
  local after = Matrix4.lookAt(
    { camera.eye.x, camera.eye.y, camera.eye.z },
    { camera.target.x, camera.target.y, camera.target.z },
    { 0, 1, 0 }
  )
  Assert.deepEqual(camera:view(1), after, "alpha one shows the current state")
  Assert.deepEqual(camera:view(0), before, "alpha zero still shows the previous state")
  Assert.deepEqual(camera:view(), camera:view(1), "nil alpha defaults to the current state")

  local half = camera:view(0.5)
  local expected = Matrix4.lookAt({
    (camera.previousEye.x + camera.eye.x) / 2,
    (camera.previousEye.y + camera.eye.y) / 2,
    (camera.previousEye.z + camera.eye.z) / 2,
  }, {
    (camera.previousTarget.x + camera.target.x) / 2,
    (camera.previousTarget.y + camera.target.y) / 2,
    (camera.previousTarget.z + camera.target.z) / 2,
  }, { 0, 1, 0 })
  Assert.deepEqual(half, expected, "half alpha looks from the midpoint state")
  Assert.deepEqual(camera:view(-0.5), camera:view(0), "alpha clamps at zero")
  Assert.deepEqual(camera:view(1.5), camera:view(1), "alpha clamps at one")
end

function T.new_bark_profile_uses_full_vertical_fov_and_exact_eye_orbit()
  local halfFov = angleIndexToRadians(0x05C1)
  local camera = FieldCamera.new(newBarkProfile(), { initialTarget = { x = 0, y = 0, z = 0 } })
  Assert.isTrue(approx(camera.eye.x, 0))
  Assert.isTrue(approx(camera.eye.y, 31.305264, 1e-5))
  Assert.isTrue(approx(camera.eye.z, 27.521307, 1e-5))
  Assert.isTrue(approx(camera:canonicalProjection()[6], 1 / math.tan(halfFov)))
end

function T.transition_adjustment_reanchors_real_camera_pairs()
  local camera = FieldCamera.new(profile(), { initialTarget = { x = 0, y = 0, z = 0 } })
  camera:setTransitionPlayer({
    renderPosition = function()
      return { x = 4, y = 5, z = 6 }
    end,
  })
  camera:adjustTransition(3, "horizontal_stairs")
  Assert.equal(camera.target.x, 5)
  Assert.equal(camera.target.y, 7)
  Assert.equal(camera.target.z, 9)
  Assert.deepEqual(camera.previousTarget, camera.target)
  Assert.deepEqual(camera.previousEye, camera.eye)
end

function T.elms_lab_profile_has_exact_canonical_orthographic_extents()
  local halfFov = angleIndexToRadians(0x0281)
  local camera = FieldCamera.new(
    profile({
      projectionType = "orthographic",
      distanceTiles = 0x0061B89B / 65536,
      angleXRaw = 0xDC82 - 0x10000,
      halfFovRadians = halfFov,
      fullVerticalFovRadians = halfFov * 2,
      nearTiles = 0x00096000 / 65536,
      farTiles = 0x006C7000 / 65536,
      targetOffsetTiles = { x = 0, y = 0, z = 0 },
    }),
    { initialTarget = { x = 0, y = 0, z = 0 } }
  )
  local projection = camera:canonicalProjection()
  Assert.isTrue(approx(1 / projection[6], 6.013033, 1e-5), "half-height")
  Assert.isTrue(approx(1 / projection[1], 8.017378, 1e-5), "half-width")
  Assert.isTrue(approx(camera.eye.y, 74.760933, 1e-5))
  Assert.isTrue(approx(camera.eye.z, 62.930273, 1e-5))
end

return { tests = T }
