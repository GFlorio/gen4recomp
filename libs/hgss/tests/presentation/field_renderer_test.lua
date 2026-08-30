-- Field presentation tests: HGSS scene policy is translated into a plain
-- frame and the queue is built once before the NDS renderer is called.

local Assert = require("tests.support.Assert")
local FieldRenderer = require("libs.hgss.src.presentation.FieldRenderer")
local Matrix4 = require("libs.math.src.Matrix4")

local T = {}

local function lightingRecord(startHalfSeconds, diffuseRgb555)
  return {
    startHalfSeconds = startHalfSeconds,
    lights = {
      { enabled = true, colorRgb555 = diffuseRgb555, vectorFx12 = { 0, 0, -4096 } },
      { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
      { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
      { enabled = false, colorRgb555 = 0, vectorFx12 = { 0, 0, 0 } },
    },
    diffuseRgb555 = diffuseRgb555,
    ambientRgb555 = 0,
    specularRgb555 = 0,
    emissionRgb555 = 0,
  }
end

function T.translates_scene_policy_and_builds_one_normalized_queue()
  local captured
  local fakeRenderer = {
    stats = {},
    draw = function(_, frame)
      captured = frame
    end,
    release = function() end,
  }
  local fieldRenderer = FieldRenderer.new({ gxRenderer = fakeRenderer })
  local view = Matrix4.identity()
  local worldProjection = Matrix4.identity()
  worldProjection[1] = 2
  local billboardProjection = Matrix4.identity()
  billboardProjection[1] = 3
  local camera = {
    zoom = 1,
    far = 400,
    view = function()
      return view
    end,
    projection = function()
      return worldProjection
    end,
    billboardProjection = function()
      return billboardProjection
    end,
  }
  local item = {
    alphaClass = "opaque",
    center = { 0, 0, 0 },
    transform = view,
    fieldEffect = "tall_grass",
  }
  local morning = lightingRecord(0, 1)
  local evening = lightingRecord(10, 2)
  local sceneRuntime = {
    lighting = { records = { morning, evening } },
    fieldTimeSeconds = 20,
    edgeColors = { [0] = 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = {} },
  }
  local ok, err = pcall(function()
    fieldRenderer:draw(
      sceneRuntime,
      camera,
      { { item } },
      nil,
      { worldViewport = { x = 0, y = 0, width = 1, height = 1 } },
      0
    )
  end)
  if not ok then
    error(err)
  end

  Assert.equal(captured.lighting, evening, "HGSS time-of-day selection happens above the NDS renderer")
  Assert.isFalse(captured.queue.opaque[1] == item, "the NDS frame owns normalized draw commands")
  Assert.equal(captured.queue.opaque[1].projection, billboardProjection)
  Assert.isNil(captured.queue.opaque[1].fieldEffect, "field-effect policy does not cross the NDS boundary")
  Assert.isNil(captured.sceneRuntime, "the normalized frame does not leak the HGSS scene runtime")
  Assert.isNil(captured.camera, "the normalized frame does not leak the camera object")
end

function T.rejects_a_missing_or_non_positive_camera_far_plane()
  local draws = 0
  local fieldRenderer = FieldRenderer.new({
    gxRenderer = {
      stats = {},
      draw = function()
        draws = draws + 1
      end,
      release = function() end,
    },
  })
  local identity = Matrix4.identity()
  local camera = {
    zoom = 1,
    far = nil,
    view = function()
      return identity
    end,
    projection = function()
      return identity
    end,
    billboardProjection = function()
      return identity
    end,
  }
  local sceneRuntime = {
    edgeColors = { [0] = 0 },
    fog = { enabled = false, color = 0, offset = 0, slope = 0, alpha = 0, table = {} },
  }
  local viewport = { worldViewport = { x = 0, y = 0, width = 1, height = 1 } }

  Assert.throws(function()
    fieldRenderer:draw(sceneRuntime, camera, nil, nil, viewport, 0)
  end)
  camera.far = 0
  Assert.throws(function()
    fieldRenderer:draw(sceneRuntime, camera, nil, nil, viewport, 0)
  end)
  camera.far = -10
  Assert.throws(function()
    fieldRenderer:draw(sceneRuntime, camera, nil, nil, viewport, 0)
  end)
  Assert.equal(draws, 0, "invalid camera configuration never reaches the GX renderer")
end

return { tests = T }
