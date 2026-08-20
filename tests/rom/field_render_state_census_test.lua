-- HGSS field visual-state census. Walks every renderable map/building model
-- and every field-actor model over the whole map catalog, resolves each
-- material's effective DS polygon state (DsMaterial + DsPolygonAttr, the
-- same normalization FieldActorModel and the map/building compilers use),
-- and pins observed source/render-state facts as a regression: polygon mode,
-- polygon alpha, polygon id, light mask, cull mode, depthEqual,
-- translucentDepthWrite, fogEnabled, texture format, texture wrap/flip,
-- alpha class, billboard occurrence, and material color source.
--
-- This is a fact census only. It records what the corpus contains, not what
-- the renderer implements; it must not be read as proof of renderer support
-- for any state it observes.
--
-- Texture format/wrap/flip/alpha-class are censused for map and building
-- materials only, where a per-area texture pack resolves the binding; field
-- actors bind textures by name within their own archive rather than an area
-- pack, and this file does not resolve that binding, so actor texture state
-- is out of scope here and not tallied. Polygon-attribute facts
-- (mode/alpha/id/lightMask/cull/depthEqual/translucentDepthWrite/
-- fogEnabled) and billboard occurrence cover map, building, AND actor
-- materials in one combined tally.
--
-- Map/building materials additionally get three cross-tabs (alphaClass x
-- fogEnabled, alphaClass x translucentDepthWrite, polygonMode x alphaClass)
-- to answer how the corpus exercises translucency and fog. The compositor is
-- a renderer contract regardless of corpus frequency: it implements exact
-- integer RGB/alpha blend, max alpha, same-ID rejection, and fog-gate state.
-- Actors are out of scope for these cross-tabs because they have no honest
-- alphaClass (see above).

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

local T = {}

-- The smallest input NitroFile's own header check can accept (NitroFile.lua's
-- NITRO_FILE_TOO_SMALL threshold, NNSG3dResFileHeader's fixed 16-byte size).
-- A building texture-pack member smaller than this cannot be a valid NSBTX
-- under any format revision, so it is the recognized "this area places no
-- buildings" stub rather than a decode failure to investigate.
local NITRO_FILE_HEADER_SIZE = 0x10

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
    -- map/building cross-tabs: whether the corpus ever pairs a
    -- translucent-ordered alpha class with fog, or sets
    -- translucentDepthWrite at all, which determines whether the supported
    -- non-depth-writing field contract still matches the corpus.
    alphaClassByFogEnabled = {},
    alphaClassByTranslucentDepthWrite = {},
    polygonModeByAlphaClass = {},
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
    local mirroredX = compiledMat.wrap.x == "repeat" and compiledMat.flip.x
    local mirroredY = compiledMat.wrap.y == "repeat" and compiledMat.flip.y
    if mirroredX or mirroredY then
      tally.mirroredRepeatCount = tally.mirroredRepeatCount + 1
    end
    local alphaUsage = compiledMat.texture and compiled.textures[compiledMat.texture].alphaUsage or nil
    local alphaClass =
      AlphaClassifier.classify(poly.polygonAlpha, poly.polygonMode, compiledMat.textureFormat or 0, alphaUsage)
    bump(tally.alphaClass, alphaClass)
    bump(tally.alphaClassByFogEnabled, alphaClass .. ":" .. tostring(poly.fogEnabled))
    bump(tally.alphaClassByTranslucentDepthWrite, alphaClass .. ":" .. tostring(poly.translucentDepthWrite))
    bump(tally.polygonModeByAlphaClass, poly.polygonMode .. ":" .. alphaClass)
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
        -- (too small to be a valid NSBTX under any format revision) means the
        -- area places no buildings. Any other decode failure is corpus
        -- corruption or a decoder regression and must propagate, not be
        -- treated as "no buildings".
        local buildingTexturePack = buildTexPacks[area.buildingTexturePackId]
        if buildingTexturePack == nil then
          local buildingTexBytes = assert(buildTexNarc:readMember(area.buildingTexturePackId))
          if #buildingTexBytes < NITRO_FILE_HEADER_SIZE then
            buildingTexturePack = false
          else
            buildingTexturePack = assert(Nsbtx.decode(buildingTexBytes, {
              alias = "building_textures",
              memberId = area.buildingTexturePackId,
            }))
          end
          buildTexPacks[area.buildingTexturePackId] = buildingTexturePack
        end
        if buildingTexturePack then
          for _, placement in ipairs(land.buildings) do
            if placement.modelMemberId ~= 0xFFFF then
              local key = table.concat({ archiveAlias, placement.modelMemberId, area.buildingTexturePackId }, ":")
              if not seenBuildings[key] then
                seenBuildings[key] = true
                local buildingModel = assert(Nsbmd.decode(assert(narc:readMember(placement.modelMemberId)), {
                  alias = archiveAlias,
                  memberId = placement.modelMemberId,
                }))
                foldFieldMaterials(tally, buildingModel.models[1].materials, buildingTexturePack)
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
-- this same census result. Pinned as a regression (2026-08-14 HeartGold
-- census) so a future dump/compiler change that starts exercising a
-- currently-absent DS feature is caught here rather than discovered in the
-- renderer or compiler.
function T.field_render_state_corpus_facts(romFs)
  local tally = newTally()
  local resolved = censusMapsAndBuildings(romFs, tally)
  censusActors(romFs, tally)

  Assert.isTrue(resolved > 0, "the census resolved renderable maps")
  Assert.isTrue(tally.materials > 0, "the census counted materials")

  -- No field material of any class (map, building, or actor) uses toon,
  -- shadow, or decal; every one is modulation.
  Assert.deepEqual(sortedKeys(tally.polygonMode), { "modulation" })

  -- Depth-equal and translucent-depth-write are never exercised anywhere in
  -- the corpus. A nonzero count means the supported field contract needs an
  -- explicit review; it is not dormant runtime support.
  Assert.equal(tally.depthEqualTrue, 0, "no material in the corpus sets depthEqual")
  Assert.equal(tally.translucentDepthWriteTrue, 0, "no material in the corpus sets translucentDepthWrite")

  -- Keep the cross-tab visible so a future census cannot hide a new
  -- unsupported combination behind the aggregate count.
  for key in pairs(tally.alphaClassByTranslucentDepthWrite) do
    Assert.isNil(
      key:match(":true$"),
      "alphaClass x translucentDepthWrite must never observe translucentDepthWrite=true: " .. key
    )
  end

  -- Ordinary translucent + fog is common and expected in the corpus; its
  -- fog contribution is handled by the per-fragment fog gate and the
  -- compositor's fog-gate AND, so this fact does not by itself imply a
  -- separate compositor requirement. This also proves the
  -- alphaClassByFogEnabled cross-tab is observed.
  Assert.isTrue(
    tally.alphaClassByFogEnabled["translucent:true"] ~= nil,
    "translucent alpha class combined with fogEnabled must occur in the corpus"
  )
  Assert.isTrue(next(tally.polygonModeByAlphaClass) ~= nil, "polygonMode x alphaClass cross-tab must be observed")

  -- Fog is heavily used across the field corpus -- this is not a corner
  -- case. This is a source/render-state fact only; the runtime schema and
  -- final-pass fog consumption are separate contracts.
  Assert.isTrue(tally.fogEnabledTrue > 0, "fogEnabled must occur somewhere in the corpus")

  -- Wireframe (polygonAlpha == 0) occurs, though rarely.
  Assert.isTrue(tally.wireframeCount > 0, "wireframe polygon alpha must occur somewhere in the corpus")

  -- Mirrored repeat (repeat-wrapped axis with its flip bit set -- a flip bit
  -- under clamp is inert and does not count) occurs, though rarely -- the
  -- corpus does not universally collapse to plain repeat.
  Assert.isTrue(tally.mirroredRepeatCount > 0, "mirrored repeat must occur somewhere in the map/building corpus")

  -- Every partial-alpha texture format (A3I5 = 1, A5I3 = 6) that appears in
  -- the map/building corpus is already covered by AlphaClassifier's
  -- translucent rule; assert they are present so that coverage is not
  -- accidentally exercising a class the corpus never reaches.
  Assert.isTrue(
    tally.textureFormat[1] ~= nil or tally.textureFormat[6] ~= nil,
    "a partial-alpha texture format occurs in the corpus"
  )
  Assert.isTrue(next(tally.textureFormat) ~= nil, "map/building texture format set must be observed")
  Assert.isTrue(next(tally.alphaClass) ~= nil, "map/building alpha class set must be observed")

  -- Field actors use camera-facing billboard projection.
  Assert.isTrue(tally.billboardShapes > 0, "billboard shapes must occur in the field-actor corpus")
end

-- ---- Regression coverage for the census's own arithmetic ----
--
-- These pin defects that a rewritten census's inline tally logic must not
-- repeat. They call this file's own module-private census helpers directly
-- (same-file locals), so they exercise the actual current behavior rather
-- than a parallel copy of it.

-- `foldFieldMaterials` must bump `mirroredRepeatCount` only when a flip flag
-- is set on an axis actually wrapped "repeat". A flip bit only mirrors an
-- axis under "repeat"; under "clamp" it is inert (SceneDescriptor.wrap
-- applies the same rule for the runtime loader). These two synthetic
-- materials (no ROM bytes; MaterialCompiler.compile accepts pre-parsed
-- high-level material records) isolate exactly that arithmetic: one flips a
-- clamped axis (must NOT count), one flips a repeated axis (must count).
local function syntheticMaterial(index, name, repeatX, flipX)
  return {
    index = index,
    name = name,
    textureName = "tex",
    repeatX = repeatX,
    repeatY = false,
    flipX = flipX,
    flipY = false,
    polyAttrRaw = 0x1F0000, -- alpha=31 (bits 16-20), mode/lightMask/flags/id all zero
    polyAttrMask = 0xFFFFFFFF,
    texImageParamRaw = 0,
    texImageParamMask = 0xFFFFFFFF,
    flagsRaw = 0,
    diffuseRgb555 = 0,
    ambientRgb555 = 0,
    specularRgb555 = 0,
    emissionRgb555 = 0,
    setVertexColor = false,
    useShininessTable = false,
  }
end

function T.mirrored_repeat_counts_only_repeat_wrap_with_flip()
  local materials = {
    syntheticMaterial(0, "flip_under_clamp", false, true),
    syntheticMaterial(1, "flip_under_repeat", true, true),
  }
  local pack = { textureByName = {} }
  local tally = newTally()
  foldFieldMaterials(tally, materials, pack)
  Assert.equal(
    tally.mirroredRepeatCount,
    1,
    "only the repeat+flip material is mirrored repeat; a flip bit under clamp wrap is inert and must not be counted"
  )
end

-- Building dedup must key on `archiveAlias:modelMemberId:buildingTexturePackId`,
-- not `archiveAlias:modelMemberId` alone. The HGSS corpus reuses the same
-- building model under more than one area texture pack (confirmed: over 100
-- (archive, model) pairs resolve to more than one distinct
-- buildingTexturePackId across the map catalog -- see the implementation
-- notes), so the compiled state (texture format/wrap/alpha class) genuinely
-- differs per pack even though the geometry is shared. This test runs the
-- real, unmodified `censusMapsAndBuildings` end-to-end and counts actual
-- `Nsbmd.decode` invocations for buildings (the true measure of the census's
-- dedup granularity), then compares that count against the independently
-- computed number of distinct (archive, model, pack) triples the corpus
-- actually contains.
function T.building_dedup_key_must_include_the_texture_pack_identity(romFs)
  local landNarc = assert(romFs:openNarc("land_data"))
  local areaNarc = assert(romFs:openNarc("area_data"))
  local correctKeys = {}
  local correctCount = 0
  for record in MapCatalog.all() do
    local r = MapResolver.resolve(romFs, record.id)
    if r and r.landDataMemberId ~= 0xFFFF then
      local area = assert(AreaData.decode(assert(areaNarc:readMember(r.areaDataMemberId)), {
        alias = "area_data",
        memberId = r.areaDataMemberId,
      }))
      local land = assert(LandData.decode(assert(landNarc:readMember(r.landDataMemberId)), {
        mapId = r.map.id,
        alias = "land_data",
        memberId = r.landDataMemberId,
      }))
      if area.areaType == "indoor" or area.areaType == "outdoor" then
        local archiveAlias = area.areaType == "indoor" and "interior_build_models" or "exterior_build_models"
        for _, placement in ipairs(land.buildings) do
          if placement.modelMemberId ~= 0xFFFF then
            local key = table.concat({ archiveAlias, placement.modelMemberId, area.buildingTexturePackId }, ":")
            if not correctKeys[key] then
              correctKeys[key] = true
              correctCount = correctCount + 1
            end
          end
        end
      end
    end
  end
  Assert.isTrue(correctCount > 0, "the corpus must contain at least one placed building to measure dedup granularity")

  local originalDecode = Nsbmd.decode
  local buildingDecodeCalls = 0
  rawset(Nsbmd, "decode", function(bytes, opts)
    if opts and (opts.alias == "interior_build_models" or opts.alias == "exterior_build_models") then
      buildingDecodeCalls = buildingDecodeCalls + 1
    end
    return originalDecode(bytes, opts)
  end)
  local ok, err = pcall(censusMapsAndBuildings, romFs, newTally())
  rawset(Nsbmd, "decode", originalDecode)
  assert(ok, err)

  Assert.equal(
    buildingDecodeCalls,
    correctCount,
    "each distinct (archive, model, texture pack) building combination must be censused once; "
      .. "today's archive:modelMemberId-only dedup key collapses a model reused across packs into one entry "
      .. string.format("(decoded %d times, corpus has %d distinct combinations)", buildingDecodeCalls, correctCount)
  )
end

-- `censusMapsAndBuildings` must not classify every `Nsbtx.decode` failure for
-- a building texture pack the same way as the one recognized case (a
-- too-small stub member meaning "this area places no buildings"). A genuine
-- decode failure on a normal-sized pack is corpus corruption or a decoder
-- regression, not an absent-buildings signal, and must fail the census
-- instead of silently continuing. This injects a simulated decode failure
-- into a real (non-stub) building texture pack reached by the actual corpus
-- walk and proves a blanket pcall-and-swallow would hide it.
function T.non_stub_nsbtx_decode_failures_must_not_be_swallowed(romFs)
  local originalDecode = Nsbtx.decode
  local injectedCount = 0
  rawset(Nsbtx, "decode", function(bytes, opts)
    if opts and opts.alias == "building_textures" and #bytes >= NITRO_FILE_HEADER_SIZE then
      injectedCount = injectedCount + 1
      error("SIMULATED_CORRUPT_BUILDING_PACK member=" .. tostring(opts.memberId), 0)
    end
    return originalDecode(bytes, opts)
  end)

  local ok = pcall(censusMapsAndBuildings, romFs, newTally())
  rawset(Nsbtx, "decode", originalDecode)

  Assert.isTrue(
    injectedCount > 0,
    "the corpus must reach at least one non-stub building texture pack to inject the failure into"
  )
  Assert.isFalse(
    ok,
    'a real (non-stub) NSBTX decode failure must propagate and fail the census, not be swallowed as "no buildings"'
  )
end

return require("tests.rom.support.RomSuite").fromFacts(T)
