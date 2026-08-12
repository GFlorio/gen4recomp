-- Draw-item tests for the actor billboard submission: the world placement and
-- the source Y anchor land in the billboard base, the ROM's polygon state rides
-- on the item, the selected pose picks its own frame mesh, and a record whose
-- visual or frame is absent is fatal rather than skipped.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
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
  for index = 1, visual.render.frameCount do
    meshes[index] = { frameIndex = index }
  end
  return { spriteId = spriteId, visual = visual, image = { id = spriteId }, meshes = meshes }
end

local function record(overrides)
  local base = {
    actorId = "map:61:object:0",
    spriteId = 99,
    world = { x = 3, y = 1.5, z = -4 },
    facing = "south",
    pose = "idle",
    poseTick = 0,
    visible = true,
  }
  for key, value in pairs(overrides or {}) do
    base[key] = value
  end
  return base
end

-- Convert an entry's visual to a static model: the surgery every static-model
-- test needs. `makeParts(render)` optionally supplies the part list before the
-- shared render fields are cleared.
local function staticModelEntry(spriteId, makeParts)
  local asset = entry(spriteId, { frameCount = 1 })
  local render = asset.visual.render
  render.kind = "staticModel"
  render.geometry.baseTransform = nil
  render.geometry.anchorTiles = { x = 0, y = 0, z = 0 }
  render.parts = makeParts and makeParts(render)
    or {
      {
        geometry = render.geometry,
        polygon = render.polygon,
        alphaClass = render.alphaClass,
      },
    }
  render.geometry, render.polygon, render.alphaClass = nil, nil, nil
  return asset
end

function T.places_the_billboard_at_the_world_position_plus_the_source_anchor()
  local item = FieldActorDraw.item(record(), entry(99))
  Assert.equal(item.billboardBase[13], 3)
  Assert.near(
    item.billboardBase[14],
    1.5 + 6 / 16,
    1e-9,
    "the loader's six-model-unit Y offset is applied in tiles, not baked into the atlas"
  )
  Assert.equal(item.billboardBase[15], -4)
  Assert.isTrue(item.transform == item.billboardBase, "the renderer resolves the same matrix it was handed")
end

-- Actor billboards draw through the depth-biased billboard projection while
-- static models keep the world projection (see FieldCamera:billboardProjection).
function T.billboard_actors_select_the_field_billboard_projection()
  local item = FieldActorDraw.item(record(), entry(99))
  Assert.isTrue(item.billboardProjection)
end

function T.static_model_actors_keep_the_world_projection()
  local item = FieldActorDraw.item(record({ spriteId = 183, facing = "north" }), staticModelEntry(183))
  Assert.isFalse(item.billboardProjection)
end

function T.places_a_static_model_without_a_billboard_transform()
  local item = FieldActorDraw.item(record({ spriteId = 183, facing = "north" }), staticModelEntry(183))
  Assert.isNil(item.billboardBase)
  Assert.equal(item.transform[13], 3)
  Assert.equal(item.transform[14], 1.5)
  Assert.equal(item.transform[15], -4)
end

function T.emits_every_static_model_part_with_its_own_material()
  local asset = staticModelEntry(183, function(render)
    return {
      { geometry = render.geometry, polygon = render.polygon, alphaClass = "opaque", textured = true },
      { geometry = render.geometry, polygon = render.polygon, alphaClass = "translucent", textured = false },
    }
  end)
  asset.meshes[2] = { frameIndex = 2 }

  local items = FieldActorDraw.items({ record({ spriteId = 183 }) }, function()
    return asset
  end)
  Assert.equal(#items, 2)
  Assert.equal(items[1].material.image, asset.image)
  Assert.isNil(items[2].material.image)
  Assert.equal(items[2].alphaClass, "translucent")
  Assert.isNil(items[1].submissionIndex, "actor items carry no submission numbers; SceneAssembly assigns them")
  Assert.isNil(items[2].submissionIndex)
end

function T.carries_the_source_polygon_state()
  local item = FieldActorDraw.item(record(), entry(99))
  Assert.equal(item.alphaClass, "cutout")
  Assert.equal(item.cullMode, "back")
  Assert.equal(item.polygonMode, "modulation")
  Assert.equal(item.polygonId, 0, "actor polygons carry the material's own id into edge marking")
  Assert.near(item.polygonAlpha, 1, 1e-9, "a 5-bit polygon alpha of 31 is fully opaque")
  Assert.equal(item.lightMask, 1)
  Assert.isFalse(item.depthEqual)
end

function T.selects_the_mesh_of_the_posed_frame()
  local idle = FieldActorDraw.item(record({ facing = "west" }), entry(99))
  Assert.equal(idle.frameIndex, 3)
  Assert.equal(idle.mesh.frameIndex, 3)

  local walking = FieldActorDraw.item(record({ facing = "west", pose = "walk", poseTick = 3 }), entry(99))
  Assert.equal(walking.frameIndex, 5, "the walk clock advances into the shared frame")
end

function T.items_skip_hidden_records_and_leave_submissions_to_assembly()
  local assets = { [99] = entry(99), [29] = entry(29) }
  local items = FieldActorDraw.items({
    record(),
    record({ actorId = "map:61:object:1", spriteId = 29, visible = false }),
  }, function(spriteId)
    return assets[spriteId]
  end)
  Assert.equal(#items, 1)
  Assert.equal(items[1].actorId, "map:61:object:0")
  Assert.isNil(items[1].submissionIndex, "the flattened scene assembly owns actor submission order")
end

function T.a_record_without_a_resident_visual_is_fatal()
  throwsCode("ACTOR_DRAW_VISUAL_MISSING", function()
    FieldActorDraw.items({ record() }, function()
      return nil
    end)
  end)
end

function T.a_frame_the_visual_cannot_provide_is_fatal()
  local incomplete = entry(99)
  incomplete.meshes = { incomplete.meshes[1] }
  throwsCode("ACTOR_DRAW_FRAME_MISSING", function()
    FieldActorDraw.item(record({ facing = "east" }), incomplete)
  end)
end

return T
