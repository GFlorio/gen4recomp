-- The player surf renderer draws the persistent surfing attachment relative
-- to the player's interpolated render position. It owns no simulation state,
-- no pool lifetime, and no logical coordinates: it translates the shared
-- static model to the player anchor plus the attachment offset and yaws it by
-- the player's facing.

local Assert = require("tests.support.Assert")
local Matrix4 = require("libs.math.src.Matrix4")
local Renderer = require("libs.hgss.src.presentation.FieldPlayerSurfRenderer")

local T = { tests = {} }

local function presentation()
  return {
    initialPlayerOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    oscillator = { initialY = 1 / 16, minY = 1 / 16, maxY = 4 / 16, stepY = (1 / 4) / 16 },
    playerBaseOffset = { x = 0, y = 4 / 16, z = 4 / 16 },
    attachmentBaseOffset = { x = 0, y = -1 / 16, z = 0 },
    yawDegrees = { north = 180, south = 0, west = 270, east = 90 },
  }
end

local function model()
  return {
    materials = {
      {
        id = 0,
        name = "surf",
        texture = "surf.png",
        wrap = { x = "clamp", y = "clamp" },
        flip = { x = false, y = false },
      },
    },
    batches = {
      {
        geometry = "surf.mesh",
        material = 0,
        alphaClass = "opaque",
        cullMode = "back",
        polygonAlpha = 31,
        polygonMode = "modulation",
        polygonId = 0,
        translucentDepthWrite = false,
        depthEqual = false,
        lightMask = 15,
        fogEnabled = false,
      },
    },
  }
end

local function pool()
  return {
    build = function(_, fn)
      return fn()
    end,
    meshFor = function()
      return { mesh = {}, center = { 0, 0, 0 } }
    end,
    imageFor = function()
      return {}
    end,
  }
end

local function renderer()
  return Renderer.new({ model = model(), presentation = presentation() }, pool())
end

local function activeStatus(facing, attachmentOffsetY)
  return {
    active = true,
    position = { x = 2, y = 0.5, z = 3 },
    facing = facing or "south",
    attachmentOffsetY = attachmentOffsetY or 0.015625,
  }
end

local function anchorOf(item)
  return { Matrix4.transformPoint(item.transform, 0, 0, 0) }
end

T.tests["draws nothing while surf is inactive"] = function()
  local items = renderer():drawItems({ active = false })
  Assert.deepEqual(items, {})
end

T.tests["anchors the attachment to the interpolated player position"] = function()
  local items = renderer():drawItems(activeStatus("south"))
  Assert.equal(#items, 1)
  local anchor = anchorOf(items[1])
  Assert.near(anchor[1], 2, 1e-9)
  Assert.near(anchor[2], 0.515625, 1e-9, "the player anchor carries the attachment Y offset")
  Assert.near(anchor[3], 3, 1e-9)
  Assert.isTrue(items[1].worldSpace, "the attachment is a world-space model draw")
end

T.tests["yaws the attachment by the player facing"] = function()
  local subject = renderer()
  local cases = {
    south = { { 3, 0.515625, 3 } },
    north = { { 1, 0.515625, 3 } },
    east = { { 2, 0.515625, 2 } },
    west = { { 2, 0.515625, 4 } },
  }
  for _, facing in ipairs({ "south", "north", "east", "west" }) do
    local items = subject:drawItems(activeStatus(facing))
    Assert.equal(#items, 1, facing .. " must draw the attachment")
    local nose = { Matrix4.transformPoint(items[1].transform, 1, 0, 0) }
    local expected = cases[facing][1]
    Assert.near(nose[1], expected[1], 1e-9, facing .. " yaw X")
    Assert.near(nose[2], expected[2], 1e-9, facing .. " yaw Y")
    Assert.near(nose[3], expected[3], 1e-9, facing .. " yaw Z")
  end
end

T.tests["follows the live attachment offset without touching the player point"] = function()
  local subject = renderer()
  local position = { x = 2, y = 0.5, z = 3 }
  local low = subject:drawItems({
    active = true,
    position = position,
    facing = "south",
    attachmentOffsetY = 0,
  })
  local high = subject:drawItems({
    active = true,
    position = position,
    facing = "south",
    attachmentOffsetY = 0.1875,
  })
  local lowAnchor = anchorOf(low[1])
  local highAnchor = anchorOf(high[1])
  Assert.near(lowAnchor[2], 0.5, 1e-9)
  Assert.near(highAnchor[2], 0.6875, 1e-9)
  Assert.deepEqual(position, { x = 2, y = 0.5, z = 3 }, "drawing must not mutate the player anchor")
end

return T
