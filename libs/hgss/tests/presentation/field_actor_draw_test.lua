-- Draw-item tests for the actor billboard submission: the world placement and
-- the source Y anchor land in the billboard base, the ROM's polygon state rides
-- on the item, the selected pose picks its own frame mesh, and a record whose
-- visual or frame is absent is fatal rather than skipped.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldActorDraw = require("libs.hgss.src.presentation.FieldActorDraw")
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
  return {
    spriteId = spriteId,
    visual = visual,
    image = { id = spriteId },
    meshes = meshes,
    billboardScales = { [visual.render.geometry] = { 1, 1, 1 } },
  }
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
  Assert.deepEqual(item.billboardCenter, { 3, 1.5 + 6 / 16, -4 })
  Assert.deepEqual(item.billboardScale, { 1, 1, 1 })
  Assert.isTrue(item.transform == item.billboardBase, "the base placement remains available to the item")
  Assert.deepEqual(item.modelNormal, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
  local nextItem = FieldActorDraw.item(record(), entry(99))
  Assert.equal(item.modelNormal, nextItem.modelNormal, "ordinary actor billboards share one identity normal")
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
  Assert.deepEqual(item.modelNormal, { 1, 0, 0, 0, 1, 0, 0, 0, 1 })
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
  Assert.equal(items[1].modelNormal, items[2].modelNormal, "translation-only static-model parts share one normal")
  Assert.isNil(
    items[1].submissionIndex,
    "actor items carry no submission numbers; ordered-part traversal owns submission order"
  )
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

function T.ordinary_billboards_reject_unsupported_alpha_classes_but_static_parts_do_not()
  for _, alphaClass in ipairs({ "translucent", "mixed", "wireframe" }) do
    local visualEntry = entry(99)
    visualEntry.visual.render.alphaClass = alphaClass
    local err = Assert.throws(function()
      FieldActorDraw.item(record(), visualEntry)
    end)
    Assert.isTrue(
      string.find(tostring(err), alphaClass, 1, true) ~= nil,
      "the unsupported billboard error names its alpha class"
    )
  end

  local staticEntry = staticModelEntry(183, function(render)
    return {
      { geometry = render.geometry, polygon = render.polygon, alphaClass = "translucent", textured = false },
    }
  end)
  local item = FieldActorDraw.item(record({ spriteId = 183 }), staticEntry)
  Assert.isFalse(item.billboardProjection, "static-model parts remain world-rendered")
  Assert.equal(item.alphaClass, "translucent")
end

function T.selects_the_mesh_of_the_posed_frame()
  local idle = FieldActorDraw.item(record({ facing = "west" }), entry(99))
  Assert.equal(idle.frameIndex, 3)
  Assert.equal(idle.mesh.frameIndex, 3)

  local walking = FieldActorDraw.item(record({ facing = "west", pose = "walk", poseTick = 3 }), entry(99))
  Assert.equal(walking.frameIndex, 5, "the walk clock advances into the shared frame")
end

function T.items_skip_hidden_records()
  local assets = { [99] = entry(99), [29] = entry(29) }
  local items = FieldActorDraw.items({
    record(),
    record({ actorId = "map:61:object:1", spriteId = 29, visible = false }),
  }, function(spriteId)
    return assets[spriteId]
  end)
  Assert.equal(#items, 1)
  Assert.equal(items[1].actorId, "map:61:object:0")
end

function T.items_into_reuses_skeletons_clears_tail_and_keeps_shared_visuals_separate()
  local asset = entry(99)
  local storage = { items = {}, actorSlots = {}, generation = 0 } --[[@as FieldActorDrawStorage]]
  local records = {
    record({ actorId = "map:61:object:0" }),
    record({ actorId = "map:61:object:1", world = { x = 8, y = 1.5, z = -4 } }),
  }
  local items = FieldActorDraw.itemsInto(records, function()
    return asset
  end, storage)
  local first, second = items[1], items[2]

  Assert.isTrue(first ~= second, "actors sharing a visual keep distinct item tables")
  Assert.isTrue(first.material ~= second.material, "actors sharing a visual keep distinct materials")
  Assert.notNil(second.billboardCenter)
  Assert.isTrue(first.billboardCenter ~= second.billboardCenter)
  Assert.equal(second.billboardCenter[1], 8)

  records[1].world.x = 9
  records[2].visible = false
  local fewer = FieldActorDraw.itemsInto(records, function()
    return asset
  end, storage)

  Assert.isTrue(fewer == items, "the item array is reusable")
  Assert.isTrue(fewer[1] == first, "a live actor keeps its item skeleton")
  Assert.isNil(fewer[2], "removed actors do not remain in the reused tail")
  Assert.equal(fewer[1].billboardCenter[1], 9)
  Assert.equal(fewer[1].transform[13], 9)
  Assert.equal(second.billboardCenter[1], 8, "one actor update does not alias another actor")

  records[2].visible = true
  local restored = FieldActorDraw.itemsInto(records, function()
    return asset
  end, storage)
  Assert.isTrue(restored[2] == second, "a hidden live actor keeps its item skeleton")
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

function T.gesture_draw_selects_strict_clip_and_applies_fixed_offset_once()
  local visual = FieldActorFixture.visual(99, { frameCount = 16 })
  visual.gestures = {
    give = {
      pose = {
        frames = { { frameIndex = 13, ticks = 22 } },
        loop = false,
        durationTicks = 22,
      },
      displayOffset = { x = 0, y = 0, z = 1 / 32 },
    },
    nurse_bow = {
      pose = {
        frames = { { frameIndex = 9, ticks = 8 } },
        loop = false,
        durationTicks = 8,
      },
      displayOffset = { x = 0, y = 0, z = 0 },
    },
  }
  local asset = {
    spriteId = 99,
    visual = visual,
    image = { id = 99 },
    meshes = {},
    billboardScales = { [visual.render.geometry] = { 1, 1, 1 } },
  }
  for index = 1, visual.render.frameCount do
    asset.meshes[index] = { frameIndex = index }
  end
  local gestureRecord = record({ gesturePose = "give", gestureTick = 5 })
  local item = FieldActorDraw.item(gestureRecord, asset)
  Assert.equal(item.frameIndex, 13, "gesture selects its own frame")
  Assert.isFalse(item.poseFellBack, "strict gesture never falls back")
  Assert.near(item.billboardBase[15], -4 + 1 / 32 + 0, 1e-9, "fixed z offset applied before anchor")
  Assert.equal(item.billboardBase[13], 3, "fixed x offset not doubled")
  -- dynamic warp offset is already in record.world, not applied again
  local warpRecord = record({ world = { x = 3, y = 1.5 + 5, z = -4 }, gesturePose = nil })
  local warpItem = FieldActorDraw.item(warpRecord, asset)
  Assert.near(warpItem.billboardBase[14], 1.5 + 5 + 6 / 16, 1e-9, "dynamic Y offset stays in world, not doubled")
end

function T.missing_gesture_clip_in_draw_is_fatal_and_warp_needs_no_clip()
  local visual = FieldActorFixture.visual(99, { frameCount = 8 })
  visual.gestures = {}
  local asset = {
    spriteId = 99,
    visual = visual,
    image = { id = 99 },
    meshes = {},
    billboardScales = { [visual.render.geometry] = { 1, 1, 1 } },
  }
  for index = 1, visual.render.frameCount do
    asset.meshes[index] = { frameIndex = index }
  end
  throwsCode("ACTOR_POSE_MISSING", function()
    FieldActorDraw.item(record({ gesturePose = "give", gestureTick = 0 }), asset)
  end)
  -- warp works without clip
  local warpOk = FieldActorDraw.item(record({ world = { x = 3, y = 6.5, z = -4 } }), asset)
  Assert.equal(warpOk.frameIndex, 2, "warp uses regular idle frame")
end

return { tests = T }
