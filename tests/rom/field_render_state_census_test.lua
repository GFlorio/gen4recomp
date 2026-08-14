-- Story 0 corpus census (renderspec.md "Freeze the HGSS visual-state corpus").
-- Walks every renderable map/building model and every field-actor model over
-- the whole map catalog, resolves each material's effective DS polygon state
-- (DsMaterial + DsPolygonAttr, the same normalization FieldActorModel and the
-- map/building compilers use) and tallies polygon mode, polygon alpha,
-- polygon id, light mask, cull mode, depthEqual, translucentDepthWrite,
-- fogEnabled, texture format, texture wrap/flip, alpha class, billboard
-- occurrence, and material color source.
--
-- Two things are checked against the SAME single-pass census:
--
-- 1. Corpus representability: every DS visual state the corpus actually uses
--    must be declared supported by `FieldRenderCapabilities` (the capability
--    contract this story also introduces). An unknown/undeclared state fails
--    here instead of silently reaching the renderer.
-- 2. Recorded research facts: the qualitative shape of what the corpus uses
--    (which polygon modes, whether depth-equal/translucent-depth-write/fog/
--    wireframe/mirrored-repeat/partial-alpha texture formats occur), pinned
--    as a regression so a future dump that starts exercising a previously
--    absent DS feature is caught here rather than in the renderer.
--
-- Texture format/wrap/flip/alpha-class are censused for map and building
-- materials only, where a per-area texture pack resolves the binding; field
-- actors bind textures by name within their own archive rather than an area
-- pack; see the implementation notes for that scope limit. Polygon-attribute
-- facts (mode/alpha/id/lightMask/cull/depthEqual/translucentDepthWrite/
-- fogEnabled) and billboard occurrence cover map, building, AND actor
-- materials in one combined tally.

local Assert = require("tests.support.Assert")
local MapCatalog = require("romdump.src.digest.MapCatalog")
local MapResolver = require("romdump.src.digest.MapResolver")
local AreaData = require("romdump.src.digest.AreaData")
local LandData = require("romdump.src.digest.LandData")
local Nsbmd = require("romdump.src.digest.nitro.Nsbmd")
local Nsbtx = require("romdump.src.digest.nitro.Nsbtx")
local DsMaterial = require("romdump.src.digest.nitro.DsMaterial")
local DsPolygonAttr = require("romdump.src.digest.nitro.DsPolygonAttr")
local MaterialCompiler = require("romdump.src.digest.MaterialCompiler")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local SbcInventory = require("romdump.src.digest.SbcInventory")

-- The capability contract this story introduces. It does not exist yet: that
-- is the intended red for this deliverable (the corpus census has no
-- declared renderer capability to check itself against).
local FieldRenderCapabilities = require("libs.engine.src.FieldRenderCapabilities")

local T = {}

local function bump(set, key)
  set[key] = (set[key] or 0) + 1
end

local function newTally()
  return {
    polygonMode = {},
    lightMask = {},
    cullMode = {},
    depthEqualTrue = 0,
    translucentDepthWriteTrue = 0,
    fogEnabledTrue = 0,
    fogEnabledFalse = 0,
    wireframeCount = 0,
    billboardShapes = 0,
    materials = 0,
    -- map/building only:
    textureFormat = {},
    wrap = {},
    flip = {},
    alphaClass = {},
    mirroredRepeatCount = 0,
    colorSource = {},
  }
end

-- Fold the effective POLYGON_ATTR state of one raw material into `tally`,
-- using `policy` to decide diffuse/ambient/specular/emission ownership
-- (only relevant for the caller's colorSource tally, when requested).
local function foldPolygon(tally, rawMaterial, policy, trackColorSource)
  local resolved = DsMaterial.resolve(rawMaterial, DsMaterial.HGSS_FIELD_DEFAULTS, policy)
  local poly = DsPolygonAttr.decode(resolved.polyAttr)
  bump(tally.polygonMode, poly.polygonMode)
  bump(tally.lightMask, poly.lightMask)
  bump(tally.cullMode, poly.cullMode)
  if poly.depthEqual then
    tally.depthEqualTrue = tally.depthEqualTrue + 1
  end
  if poly.translucentDepthWrite then
    tally.translucentDepthWriteTrue = tally.translucentDepthWriteTrue + 1
  end
  if poly.fogEnabled then
    tally.fogEnabledTrue = tally.fogEnabledTrue + 1
  else
    tally.fogEnabledFalse = tally.fogEnabledFalse + 1
  end
  if poly.polygonAlpha == 0 then
    tally.wireframeCount = tally.wireframeCount + 1
  end
  if trackColorSource then
    for _, channel in ipairs({ "diffuse", "ambient", "specular", "emission" }) do
      bump(tally.colorSource, channel .. ":" .. resolved.colors[channel].source)
    end
  end
  return poly
end

-- Map/building materials: full state including texture format/wrap/flip/
-- alpha class, resolved against the confirmed HGSS field-model color policy
-- (docs/rendering.md "Normalized material state"; DsMaterial.applyFieldPolicy).
local function foldFieldMaterials(tally, materials, texPack)
  local compiled = MaterialCompiler.compile(materials, texPack, {})
  for i, rawMaterial in ipairs(materials) do
    tally.materials = tally.materials + 1
    local poly = foldPolygon(tally, rawMaterial, DsMaterial.applyFieldPolicy(rawMaterial), true)
    local compiledMat = compiled.materials[i]
    bump(tally.textureFormat, compiledMat.textureFormat or "untextured")
    bump(tally.wrap, compiledMat.wrap.x .. "/" .. compiledMat.wrap.y)
    bump(tally.flip, tostring(compiledMat.flip.x) .. "/" .. tostring(compiledMat.flip.y))
    if compiledMat.flip.x or compiledMat.flip.y then
      tally.mirroredRepeatCount = tally.mirroredRepeatCount + 1
    end
    local alphaUsage = compiledMat.texture and compiled.textures[compiledMat.texture].alphaUsage or nil
    bump(tally.alphaClass, AlphaClassifier.classify(poly.polygonAlpha, compiledMat.textureFormat or 0, alphaUsage))
  end
end

-- Field-actor materials: polygon-attribute state only (no per-area texture
-- pack to resolve a bound format from). Ownership is read as the material's
-- own flags rather than forcing the map/building field policy, since no
-- production reference confirms actors share that exact color policy.
local function foldActorMaterials(tally, materials)
  for _, rawMaterial in ipairs(materials) do
    tally.materials = tally.materials + 1
    foldPolygon(tally, rawMaterial, DsMaterial.ownership(rawMaterial.flagsRaw), false)
  end
end

local function censusMapsAndBuildings(romFs, tally)
  local landNarc = assert(romFs:openNarc("land_data"))
  local areaNarc = assert(romFs:openNarc("area_data"))
  local mapTexNarc = assert(romFs:openNarc("map_textures"))
  local buildTexNarc = assert(romFs:openNarc("building_textures"))
  local buildingNarcs, mapTexPacks, buildTexPacks, seenBuildings = {}, {}, {}, {}
  local resolved = 0

  for record in MapCatalog.all() do
    local r = MapResolver.resolve(romFs, record.id)
    if r and r.landDataMemberId ~= 0xFFFF then
      resolved = resolved + 1
      local area = assert(AreaData.decode(assert(areaNarc:readMember(r.areaDataMemberId)), {
        alias = "area_data",
        memberId = r.areaDataMemberId,
      }))
      local land = assert(LandData.decode(assert(landNarc:readMember(r.landDataMemberId)), {
        mapId = r.map.id,
        alias = "land_data",
        memberId = r.landDataMemberId,
      }))
      local model = assert(Nsbmd.decode(land.mapModelBytes, {
        alias = "land_data",
        memberId = r.landDataMemberId,
        section = "map-model",
      }))
      local pack = mapTexPacks[area.mapTexturePackId]
      if not pack then
        pack = assert(Nsbtx.decode(assert(mapTexNarc:readMember(area.mapTexturePackId)), {
          alias = "map_textures",
          memberId = area.mapTexturePackId,
        }))
        mapTexPacks[area.mapTexturePackId] = pack
      end
      foldFieldMaterials(tally, model.models[1].materials, pack)

      if area.areaType == "indoor" or area.areaType == "outdoor" then
        local archiveAlias = area.areaType == "indoor" and "interior_build_models" or "exterior_build_models"
        local narc = buildingNarcs[archiveAlias]
        if not narc then
          narc = assert(romFs:openNarc(archiveAlias))
          buildingNarcs[archiveAlias] = narc
        end
        -- Not every area defines real building content; a stub pack member
        -- (too small to be a valid NSBTX) means the area places no buildings.
        local bpack = buildTexPacks[area.buildingTexturePackId]
        if bpack == nil then
          local ok, decoded = pcall(Nsbtx.decode, assert(buildTexNarc:readMember(area.buildingTexturePackId)), {
            alias = "building_textures",
            memberId = area.buildingTexturePackId,
          })
          bpack = ok and decoded or false
          buildTexPacks[area.buildingTexturePackId] = bpack
        end
        if bpack then
          for _, placement in ipairs(land.buildings) do
            if placement.modelMemberId ~= 0xFFFF then
              local key = archiveAlias .. ":" .. placement.modelMemberId
              if not seenBuildings[key] then
                seenBuildings[key] = true
                local buildingModel = assert(Nsbmd.decode(assert(narc:readMember(placement.modelMemberId)), {
                  alias = archiveAlias,
                  memberId = placement.modelMemberId,
                }))
                foldFieldMaterials(tally, buildingModel.models[1].materials, bpack)
              end
            end
          end
        end
      end
    end
  end
  return resolved
end

local MODEL_MAGIC = "BMD0"

local function censusActors(romFs, tally)
  for _, alias in ipairs({ "field_actor_models", "field_static_models" }) do
    local narc = assert(romFs:openNarc(alias))
    for memberId = 0, narc:memberCount() - 1 do
      local bytes = assert(narc:readMember(memberId))
      if bytes:sub(1, 4) == MODEL_MAGIC then
        local model = assert(Nsbmd.decode(bytes, { alias = alias, memberId = memberId }))
        foldActorMaterials(tally, model.models[1].materials)
        local inventory = SbcInventory.inspectModel(model.models[1])
        tally.billboardShapes = tally.billboardShapes + #inventory.billboardShapes
      end
    end
  end
end

local function sortedKeys(set)
  local keys = {}
  for key in pairs(set) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

-- One pass over the corpus; every postcondition below is asserted against
-- this same census result.
function T.field_render_state_corpus_is_representable_by_declared_capabilities(romFs)
  local tally = newTally()
  local resolved = censusMapsAndBuildings(romFs, tally)
  censusActors(romFs, tally)

  Assert.isTrue(resolved > 0, "the census resolved renderable maps")
  Assert.isTrue(tally.materials > 0, "the census counted materials")

  -- ---- Corpus representability against the declared capability contract ----

  Assert.notNil(FieldRenderCapabilities.polygonModes, "FieldRenderCapabilities must declare polygonModes")
  for _, mode in ipairs(sortedKeys(tally.polygonMode)) do
    Assert.isTrue(
      FieldRenderCapabilities.polygonModes[mode] == true,
      "polygon mode " .. mode .. " must be declared supported"
    )
  end

  Assert.notNil(FieldRenderCapabilities.cullModes, "FieldRenderCapabilities must declare cullModes")
  for _, mode in ipairs(sortedKeys(tally.cullMode)) do
    Assert.isTrue(
      FieldRenderCapabilities.cullModes[mode] == true,
      "cull mode " .. mode .. " must be declared supported"
    )
  end

  Assert.notNil(FieldRenderCapabilities.textureFormats, "FieldRenderCapabilities must declare textureFormats")
  for _, format in ipairs(sortedKeys(tally.textureFormat)) do
    if format ~= "untextured" then
      Assert.isTrue(
        FieldRenderCapabilities.textureFormats[format] == true,
        "texture format " .. tostring(format) .. " must be declared supported"
      )
    end
  end

  Assert.notNil(FieldRenderCapabilities.alphaClasses, "FieldRenderCapabilities must declare alphaClasses")
  for _, class in ipairs(sortedKeys(tally.alphaClass)) do
    Assert.isTrue(
      FieldRenderCapabilities.alphaClasses[class] == true,
      "alpha class " .. class .. " must be declared supported"
    )
  end

  if tally.depthEqualTrue > 0 then
    Assert.isTrue(
      FieldRenderCapabilities.depthEqual == true,
      "depthEqual is exercised by the corpus and must be declared supported"
    )
  end
  if tally.translucentDepthWriteTrue > 0 then
    Assert.isTrue(
      FieldRenderCapabilities.translucentDepthWrite == true,
      "translucentDepthWrite is exercised by the corpus and must be declared supported"
    )
  end
  if tally.fogEnabledTrue > 0 then
    Assert.isTrue(
      FieldRenderCapabilities.fog == true,
      "fogEnabled is exercised by the corpus and must be declared supported"
    )
  end
  if tally.wireframeCount > 0 then
    Assert.isTrue(
      FieldRenderCapabilities.wireframe == true,
      "wireframe is exercised by the corpus and must be declared supported"
    )
  end
  if tally.mirroredRepeatCount > 0 then
    Assert.isTrue(
      FieldRenderCapabilities.mirroredRepeat == true,
      "mirrored repeat is exercised by the corpus and must be declared supported"
    )
  end
  if tally.billboardShapes > 0 then
    Assert.isTrue(
      FieldRenderCapabilities.billboard == true,
      "billboard projection is exercised by the corpus and must be declared supported"
    )
  end

  -- ---- Recorded research facts (2026-08-14 HeartGold census) ----
  --
  -- Pinned so a future dump/compiler change that starts exercising a
  -- currently-absent DS feature is caught here, not discovered in the
  -- renderer. See the implementation notes for the full research summary.

  -- No field material of any class (map, building, or actor) uses toon,
  -- shadow, or decal; every one is modulation.
  Assert.deepEqual(sortedKeys(tally.polygonMode), { "modulation" })

  -- Depth-equal and translucent-depth-write are never exercised anywhere in
  -- the corpus (Story 8/9's research question).
  Assert.equal(tally.depthEqualTrue, 0, "no material in the corpus sets depthEqual")
  Assert.equal(tally.translucentDepthWriteTrue, 0, "no material in the corpus sets translucentDepthWrite")

  -- Fog is heavily used across the field corpus -- this is not a corner case.
  Assert.isTrue(tally.fogEnabledTrue > 0, "fogEnabled must occur somewhere in the corpus")

  -- Wireframe (polygonAlpha == 0) occurs, though rarely.
  Assert.isTrue(tally.wireframeCount > 0, "wireframe polygon alpha must occur somewhere in the corpus")

  -- Mirrored repeat (TEXIMAGE_PARAM flip bits with repeat enabled) occurs,
  -- though rarely -- the corpus does not universally collapse to plain repeat.
  Assert.isTrue(tally.mirroredRepeatCount > 0, "mirrored repeat must occur somewhere in the map/building corpus")

  -- Every partial-alpha texture format (A3I5 = 1, A5I3 = 6) that appears in
  -- the map/building corpus is already covered by AlphaClassifier's
  -- translucent rule; assert they are present so that coverage is not
  -- accidentally exercising a class the corpus never reaches.
  Assert.isTrue(
    tally.textureFormat[1] ~= nil or tally.textureFormat[6] ~= nil,
    "a partial-alpha texture format occurs in the corpus"
  )

  -- Field actors use camera-facing billboard projection.
  Assert.isTrue(tally.billboardShapes > 0, "billboard shapes must occur in the field-actor corpus")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
