-- Draw-item tests for the actor billboard submission: the world placement and
-- the source Y anchor land in the billboard base, the ROM's polygon state rides
-- on the item, the selected pose picks its own frame mesh, and a record whose
-- visual or frame is absent is fatal rather than skipped.

local Assert = require("tests.support.Assert")
local Errors = require("libs.rom.src.Errors")
local FieldActorDraw = require("libs.engine.src.FieldActorDraw")
local FieldActorFixture = require("tests.support.FieldActorFixture")

local T = {}

local function throwsCode(code, fn)
  local err = Assert.throws(fn)
  Assert.isTrue(Errors.is(err), "expected a structured error, got " .. tostring(err))
  Assert.equal(err.code, code, "expected " .. code .. ", got " .. Errors.format(err))
end

local function entry(spriteId, opts)
  local visual = FieldActorFixture.visual(spriteId, opts)
  local meshes = {}
  for index = 1, visual.render.frameCount do meshes[index] = { frameIndex = index } end
  return { spriteId = spriteId, visual = visual, image = { id = spriteId }, meshes = meshes }
end

local function record(overrides)
  local base = {
    actorId = "map:61:object:0", spriteId = 99,
    world = { x = 3, y = 1.5, z = -4 },
    facing = "south", pose = "idle", poseTick = 0, visible = true,
  }
  for key, value in pairs(overrides or {}) do base[key] = value end
  return base
end

function T.places_the_billboard_at_the_world_position_plus_the_source_anchor()
  local item = FieldActorDraw.item(record(), entry(99), 1)
  Assert.equal(item.billboardBase[13], 3)
  Assert.near(item.billboardBase[14], 1.5 + 6 / 16, 1e-9,
    "the loader's six-model-unit Y offset is applied in tiles, not baked into the atlas")
  Assert.equal(item.billboardBase[15], -4)
  Assert.isTrue(item.transform == item.billboardBase,
    "the renderer resolves the same matrix it was handed")
end

function T.places_a_static_model_without_a_billboard_transform()
  local asset = entry(183, { frameCount = 1 })
  local render = asset.visual.render
  render.kind = "staticModel"
  render.geometry.baseTransform = nil
  render.geometry.anchorTiles = { x = 0, y = 0, z = 0 }
  render.parts = { {
    geometry = render.geometry,
    polygon = render.polygon,
    alphaClass = render.alphaClass,
  } }
  render.geometry, render.polygon, render.alphaClass = nil, nil, nil
  local item = FieldActorDraw.item(record({ spriteId = 183, facing = "north" }), asset, 1)
  Assert.isNil(item.billboardBase)
  Assert.equal(item.transform[13], 3)
  Assert.equal(item.transform[14], 1.5)
  Assert.equal(item.transform[15], -4)
end

function T.emits_every_static_model_part_with_its_own_material()
  local asset = entry(183, { frameCount = 1 })
  local render = asset.visual.render
  local geometry, polygon = render.geometry, render.polygon
  render.kind = "staticModel"
  render.parts = {
    { geometry = geometry, polygon = polygon, alphaClass = "opaque", textured = true },
    { geometry = geometry, polygon = polygon, alphaClass = "translucent", textured = false },
  }
  render.geometry, render.polygon, render.alphaClass = nil, nil, nil
  asset.meshes[2] = { frameIndex = 2 }

  local items = FieldActorDraw.items({ record({ spriteId = 183 }) },
    function() return asset end)
  Assert.equal(#items, 2)
  Assert.equal(items[1].material.image, asset.image)
  Assert.isNil(items[2].material.image)
  Assert.equal(items[2].alphaClass, "translucent")
  Assert.isTrue(items[1].submissionIndex ~= items[2].submissionIndex)
end

function T.carries_the_source_polygon_state()
  local item = FieldActorDraw.item(record(), entry(99), 1)
  Assert.equal(item.alphaClass, "cutout")
  Assert.equal(item.cullMode, "back")
  Assert.equal(item.polygonMode, "modulation")
  Assert.equal(item.polygonId, 0, "actor polygons carry the material's own id into edge marking")
  Assert.near(item.polygonAlpha, 1, 1e-9, "a 5-bit polygon alpha of 31 is fully opaque")
  Assert.equal(item.lightMask, 1)
  Assert.isFalse(item.depthEqual)
end

function T.selects_the_mesh_of_the_posed_frame()
  local idle = FieldActorDraw.item(record({ facing = "west" }), entry(99), 1)
  Assert.equal(idle.frameIndex, 3)
  Assert.equal(idle.mesh.frameIndex, 3)

  local walking = FieldActorDraw.item(
    record({ facing = "west", pose = "walk", poseTick = 3 }), entry(99), 1)
  Assert.equal(walking.frameIndex, 5, "the walk clock advances into the shared frame")
end

function T.items_skip_hidden_records_and_number_submissions_after_the_scene()
  local assets = { [99] = entry(99), [29] = entry(29) }
  local items = FieldActorDraw.items({
    record(), record({ actorId = "map:61:object:1", spriteId = 29, visible = false }),
  }, function(spriteId) return assets[spriteId] end)
  Assert.equal(#items, 1)
  Assert.isTrue(items[1].submissionIndex > FieldActorDraw.SUBMISSION_BASE,
    "actor draws submit after map and building batches")
end

function T.a_record_without_a_resident_visual_is_fatal()
  throwsCode("ACTOR_DRAW_VISUAL_MISSING", function()
    FieldActorDraw.items({ record() }, function() return nil end)
  end)
end

function T.a_frame_the_visual_cannot_provide_is_fatal()
  local incomplete = entry(99)
  incomplete.meshes = { incomplete.meshes[1] }
  throwsCode("ACTOR_DRAW_FRAME_MISSING", function()
    FieldActorDraw.item(record({ facing = "east" }), incomplete, 1)
  end)
end

return T
