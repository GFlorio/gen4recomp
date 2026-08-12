-- MaterialEvaluator tests: the per-frame effective material state -- NSBTA
-- UV transforms, NSBTP texture/palette switching, NSBMA colors and alpha,
-- the recomputed render classification -- over hand-built compiled clips.
-- Pure domain; no rendering, no love.

local Assert = require("tests.support.Assert")
local ModelDefinition = require("libs.engine.src.ModelDefinition")
local ModelInstance = require("libs.engine.src.ModelInstance")
local MaterialEvaluator = require("libs.engine.src.MaterialEvaluator")

local T = {}

local function throwsCode(code, fn)
  local ok, result = pcall(fn)
  if ok then
    error("expected a structured " .. code .. " error, got a result")
  end
  Assert.equal(result.code, code)
end

-- ---- fixture helpers ----

-- A texsrt clip: translation-S curve (the Maya convention's scroll
-- channel -- the real `wind` clip animates transS), identity scale and
-- rotation (spelled as the explicit constants the compiler emits).
local function scrollClip(frames, transKeys)
  return {
    id = "fixture:scroll",
    name = "scroll",
    category = "material",
    kind = "texsrt",
    frameCount = frames,
    tracks = { { target = "wall", targetIndex = 0 } },
    source = { type = "nitro", format = "NSBTA" },
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
            rot = { source = "constant", value = 0x10000000 },
            transS = { source = "curve", rate = 1, limit = frames - 1, storage = "fx32", keys = transKeys },
            transT = { source = "constant", value = 0 },
          },
        },
      },
    },
  }
end

-- A pattern clip: 4-frame keys selecting among two texture variants and
-- alternating palettes.
local function patternClip()
  return {
    id = "fixture:pattern",
    name = "pattern",
    category = "material",
    kind = "pattern",
    frameCount = 8,
    tracks = { { target = "wall", targetIndex = 0 } },
    source = { type = "nitro", format = "NSBTP" },
    compiled = {
      numTextures = 2,
      numPalettes = 2,
      textureNames = { "sign.a", "sign.b" },
      paletteNames = { "sign.a_pl", "sign.b_pl" },
      targets = {
        {
          index = 0,
          name = "wall",
          rate = 0x800,
          keyCount = 4,
          keys = {
            { frame = 0, texIdx = 0, plttIdx = 0xFF },
            { frame = 2, texIdx = 1, plttIdx = 0xFF },
            { frame = 4, texIdx = 0, plttIdx = 1 },
            { frame = 6, texIdx = 1, plttIdx = 1 },
          },
        },
      },
    },
  }
end

-- A color clip: constant colors, alpha fading 31 -> 0 over the frames.
local function fadeClip(frames)
  local alphaKeys = {}
  for f = 0, frames - 1 do
    alphaKeys[f + 1] = math.max(0, 31 - f)
  end
  return {
    id = "fixture:fade",
    name = "fade",
    category = "material",
    kind = "color",
    frameCount = frames,
    tracks = { { target = "wall", targetIndex = 0 } },
    source = { type = "nitro", format = "NSBMA" },
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            diffuse = { source = "constant", value = 0x7FFF }, -- white
            ambient = { source = "constant", value = 0x4210 },
            specular = { source = "constant", value = 0x0000 },
            emission = { source = "constant", value = 0x001F }, -- blue
            alpha = { source = "curve", rate = 1, limit = frames - 1, isAlpha = true, keys = alphaKeys },
          },
        },
      },
    },
  }
end

-- A one-material textured model with a base texture and two pattern
-- variants. The base texture is 64x64 with binary alpha (cutout); variant
-- "sign.b" is 32x32 with no alpha (opaque).
local function texturedDefinition(opts)
  opts = opts or {}
  return ModelDefinition.new({
    key = "fixture:sign",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = { { id = "sign", nodeIndex = 0, materialIndex = 0, geometry = "fixtures/sign.g4mesh" } },
    materials = {
      {
        id = 0,
        name = "wall",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
        texture = "base.png",
        texWidth = 64,
        texHeight = 64,
        textureFormat = 3,
        alphaUsage = { hasZero = true },
        polygonAlpha = 31,
        texMtxMode = opts.texMtxMode or 0,
        variants = {
          {
            name = "sign.a",
            texture = "sign-a.png",
            width = 64,
            height = 64,
            textureFormat = 3,
            alphaUsage = { hasZero = true },
          },
          {
            name = "sign.b",
            texture = "sign-b.png",
            width = 32,
            height = 32,
            textureFormat = 7,
            alphaUsage = nil,
          },
          {
            name = "sign.a+sign.a_pl",
            texture = "sign-a-pl.png",
            width = 64,
            height = 64,
            textureFormat = 3,
            alphaUsage = { hasZero = true },
          },
          {
            name = "sign.b+sign.b_pl",
            texture = "sign-b-pl.png",
            width = 32,
            height = 32,
            textureFormat = 7,
            alphaUsage = nil,
          },
          {
            name = "sign.a+sign.b_pl",
            texture = "sign-a-b-pl.png",
            width = 64,
            height = 64,
            textureFormat = 3,
            alphaUsage = { hasZero = true },
          },
          {
            name = "sign.b+sign.a_pl",
            texture = "sign-b-a-pl.png",
            width = 32,
            height = 32,
            textureFormat = 7,
            alphaUsage = nil,
          },
        },
      },
    },
    skins = {},
    animations = {},
  })
end

-- A definition whose animations list carries the given clips (play resolves
-- clips through the definition).
local function definitionWith(def, clips)
  return ModelDefinition.new({
    key = def.key,
    nodes = def.nodes,
    meshes = def.meshes,
    materials = def.materials,
    skins = def.skins,
    animations = clips,
    backend = def.backend,
  })
end

local function instanceWith(def, clips)
  local instance = ModelInstance.new(definitionWith(def, clips))
  for _, clip in ipairs(clips or {}) do
    instance:play(clip.name)
  end
  instance:evaluateMaterials()
  return instance
end

-- ---- NSBTA: scrolling UV ----
--
-- The matrix translation lives in the DS TEXCOORD domain: TEXCOORD
-- coordinates are 1.11.4 fixed point, the display-list decoder divides
-- them by 16 to get texels, and the Maya translation formula carries the
-- matching <<4 factors (NitroTexMatrix). The translation cells therefore
-- divide by an extra 16 over the linear cells:
--
--   m02 = cells[5] / (4096 * 16 * curW)   m12 = cells[6] / (4096 * 16 * curH)
--
-- so a transS of one fx32 unit (0x1000) moves the UV by exactly one
-- normalized texture width, and on a 64x64 texture one texel is transS =
-- 0x40 (m02 = -1/64).

-- A transS of 0x1000 (one whole texture width in fx32) is exactly one
-- texture repeat of translation, not sixteen.
function T.scrolling_uv_advances_one_texture_width_per_0x1000()
  local def = texturedDefinition()
  local clip = scrollClip(4, { 0x0, 0x1000, 0x2000, 0x3000 })
  local instance = instanceWith(def, { clip })
  Assert.near(instance.materialState[0].texMatrix[7], 0, 1e-9)
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.near(instance.materialState[0].texMatrix[7], -1, 1e-9)
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.near(instance.materialState[0].texMatrix[7], -2, 1e-9)
  -- The texture does not change: same texture key and dimensions.
  Assert.equal(instance.materialState[0].texture, "base.png")
  Assert.equal(instance.materialState[0].texWidth, 64)
end

-- On a 64x64 texture one texel is 1/64 of the normalized width: transS =
-- 0x40 translates exactly one texel (m02 == -1/64).
function T.scrolling_0x40_translates_exactly_one_texel_on_a_64px_texture()
  local def = texturedDefinition()
  local clip = scrollClip(2, { 0x0, 0x40 })
  local instance = instanceWith(def, { clip })
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.near(instance.materialState[0].texMatrix[7], -1 / 64, 1e-9)
end

-- transS = 0x100 is a sixteenth of the texture width: four texels on a
-- 64px texture (m02 == -1/16).
function T.scrolling_0x100_translates_a_sixteenth_of_the_texture_width()
  local def = texturedDefinition()
  local clip = scrollClip(2, { 0x0, 0x100 })
  local instance = instanceWith(def, { clip })
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.near(instance.materialState[0].texMatrix[7], -1 / 16, 1e-9)
end

-- ---- NSBTA: rotating UV ----

function T.rotating_uv_swaps_the_axis_cells()
  local def = texturedDefinition()
  -- A 4-frame 90-degree rotation: sin/cos keys (0,1) -> (1,0).
  local clip = {
    id = "fixture:spin",
    name = "spin",
    category = "material",
    kind = "texsrt",
    frameCount = 4,
    tracks = { { target = "wall", targetIndex = 0 } },
    source = { type = "nitro", format = "NSBTA" },
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            transS = { source = "constant", value = 0 },
            transT = { source = "constant", value = 0 },
            rot = {
              source = "curve",
              rate = 1,
              limit = 3,
              storage = "fx32",
              keys = {
                0x10000000, -- frame 0: identity
                0x1000, -- frame 1: sin = 1, cos = 0 (90 degrees)
                0x10000000,
                0x10000000,
              },
            },
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
          },
        },
      },
    },
  }
  -- sin=0x1000, cos=0 at frame 1: c00 = cos = 0, c11 = 0, c01/c10
  -- = ± sin * aspect. The matrix must map u to v and v to -u.
  local instance = instanceWith(def, { clip })
  instance:updateFixed()
  instance:evaluateMaterials()
  local m = instance.materialState[0].texMatrix
  Assert.near(m[1], 0, 1e-9) -- m00 = c00/4096 = 0
  Assert.near(m[5], 0, 1e-9) -- m11 = c11/4096 = 0
  -- c01 = asr(-sin * fxDiv(h, w), 12) = -0x1000; m10 = c01/(4096) = -1.
  Assert.near(m[2], -1, 1e-9)
  Assert.near(m[4], 1, 1e-9)
end

-- The Maya rotation variant (transOne + scaleOne, flagTS_) folds a
-- center-compensation translation into c20/c21. That translation is in the
-- same 1.11.4 TEXCOORD domain, so it divides by the same extra 16:
-- m02 = c20 / (4096 * 16 * w), m12 = c21 / (4096 * 16 * h). With
-- sin = 0x800 and cos = 0xDD7 on a 64x64 texture:
--   c20 = (w * (0x1000 - sin - cos)) << 3 = -765440
--   c21 = (h * (0x1000 + sin - cos)) << 3 = 1331712
-- giving m02 = -1495/8192 and m12 = 2601/8192.
function T.rotating_uv_center_compensation_translates_in_texcoord_fixed_point()
  local def = texturedDefinition()
  local clip = {
    id = "fixture:spin45",
    name = "spin45",
    category = "material",
    kind = "texsrt",
    frameCount = 4,
    tracks = { { target = "wall", targetIndex = 0 } },
    source = { type = "nitro", format = "NSBTA" },
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            transS = { source = "constant", value = 0 },
            transT = { source = "constant", value = 0 },
            rot = {
              source = "curve",
              rate = 1,
              limit = 3,
              storage = "fx32",
              keys = { 0x0DD70800, 0x0DD70800, 0x0DD70800, 0x0DD70800 },
            },
            scaleS = { source = "constant", value = 0x1000 },
            scaleT = { source = "constant", value = 0x1000 },
          },
        },
      },
    },
  }
  local instance = instanceWith(def, { clip })
  instance:updateFixed()
  instance:evaluateMaterials()
  local m = instance.materialState[0].texMatrix
  Assert.near(m[7], -1495 / 8192, 1e-9)
  Assert.near(m[8], 2601 / 8192, 1e-9)
end

-- The Maya scale variant (transOne + rotOne, flagTR_) carries the
-- (0x2000 - 2 * scaleT) anchor in c21 -- also a TEXCOORD translation, so
-- m12 = c21 / (4096 * 16 * h). At scaleT = 0x1800 on a 64px texture:
-- c21 = (h * (0x2000 - 2 * scaleT)) << 3 = -2097152 -> m12 = -1/2. The
-- linear cells keep their 1.3.12 scale: m00 = 0x2000/4096 = 2,
-- m11 = 0x1800/4096 = 3/2.
function T.scaling_uv_anchor_translates_in_texcoord_fixed_point()
  local def = texturedDefinition()
  local clip = {
    id = "fixture:stretch",
    name = "stretch",
    category = "material",
    kind = "texsrt",
    frameCount = 4,
    tracks = { { target = "wall", targetIndex = 0 } },
    source = { type = "nitro", format = "NSBTA" },
    compiled = {
      targets = {
        {
          index = 0,
          name = "wall",
          channels = {
            transS = { source = "constant", value = 0 },
            transT = { source = "constant", value = 0 },
            rot = { source = "constant", value = 0x10000000 },
            scaleS = { source = "constant", value = 0x2000 },
            scaleT = { source = "constant", value = 0x1800 },
          },
        },
      },
    },
  }
  local instance = instanceWith(def, { clip })
  local m = instance.materialState[0].texMatrix
  Assert.near(m[1], 2, 1e-9)
  Assert.near(m[5], 1.5, 1e-9)
  Assert.near(m[7], 0, 1e-9)
  Assert.near(m[8], -0.5, 1e-9)
end

-- ---- NSBTP: texture and palette switching ----

function T.pattern_switches_texture_and_palette_variants()
  local def = texturedDefinition()
  local instance = instanceWith(def, { patternClip() })
  local state = instance.materialState[0]
  Assert.equal(state.texture, "sign-a.png")
  Assert.equal(state.texWidth, 64)
  -- Frame 3: the active key (frame 2) selects the second texture at 32x32.
  instance:updateFixed()
  instance:updateFixed()
  instance:updateFixed()
  instance:evaluateMaterials()
  state = instance.materialState[0]
  Assert.equal(state.texture, "sign-b.png")
  Assert.equal(state.texWidth, 32)
  -- Frame 5: the active key (frame 4) keeps texture a with palette b.
  instance:updateFixed()
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.equal(instance.materialState[0].texture, "sign-a-b-pl.png")
  -- Frame 7: texture b with palette b.
  instance:updateFixed()
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.equal(instance.materialState[0].texture, "sign-b-pl.png")
end

-- ---- NSBMA: color and alpha ----

-- A record carrying the optional colors block (the four DS base-material
-- registers the dynamic compiler emits) seeds the evaluated state per
-- component; records without the block keep the baseColor reconstruction.
-- The evaluated colors are what NSBMA channel overrides mutate, so the base
-- channels must be the material's own, not a uniform baseColor.
function T.base_material_state_reads_per_component_colors()
  local def = texturedDefinition()
  def.materials[1].colors = {
    diffuse = { r = 255, g = 0, b = 0 },
    ambient = { r = 0, g = 255, b = 0 },
    specular = { r = 0, g = 0, b = 255 },
    emission = { r = 123, g = 123, b = 123 },
  }
  local instance = ModelInstance.new(def)
  instance:evaluateMaterials()
  local state = instance.materialState[0]
  Assert.equal(state.colors.diffuse.r, 255)
  Assert.equal(state.colors.diffuse.g, 0)
  Assert.equal(state.colors.ambient.g, 255)
  Assert.equal(state.colors.specular.b, 255)
  Assert.equal(state.colors.emission.r, 123)
  Assert.equal(state.colors.emission.g, 123)
  Assert.equal(state.colors.emission.b, 123)
  -- The effective render material carries the same per-component colors.
  local m = instance:effectiveMaterial(0)
  Assert.deepEqual(m.matDiffuse, { 1, 0, 0 })
  Assert.deepEqual(m.matAmbient, { 0, 1, 0 })
  Assert.deepEqual(m.matSpecular, { 0, 0, 1 })
  Assert.near(m.matEmission[1], 123 / 255, 1e-9)
end

function T.color_clip_animates_diffuse_and_alpha()
  local def = texturedDefinition()
  local instance = instanceWith(def, { fadeClip(4) })
  local state = instance.materialState[0]
  -- White diffuse, blue emission, alpha 31.
  Assert.equal(state.colors.diffuse.r, 255)
  Assert.equal(state.colors.diffuse.g, 255)
  Assert.equal(state.colors.diffuse.b, 255)
  Assert.equal(state.colors.emission.b, 255)
  Assert.equal(state.polygonAlpha, 31)
  Assert.equal(state.alphaClass, "cutout") -- binary-alpha base texture
  instance:updateFixed()
  instance:updateFixed()
  instance:evaluateMaterials()
  state = instance.materialState[0]
  Assert.equal(state.polygonAlpha, 29)
  Assert.equal(state.alphaClass, "translucent", "polygon alpha below 31 migrates")
end

-- ---- render classification migration ----

function T.class_migrates_with_the_selected_texture()
  local def = texturedDefinition()
  -- No animation: the base texture's binary alpha classifies as cutout.
  local instance = instanceWith(def, {})
  Assert.equal(instance.materialState[0].alphaClass, "cutout")
  -- Frame 3 of the pattern: variant "sign.b" has no alpha (format 7):
  -- the class migrates to opaque while the polygon alpha stays 31.
  local animated = instanceWith(def, { patternClip() })
  animated:updateFixed()
  animated:updateFixed()
  animated:updateFixed()
  animated:evaluateMaterials()
  Assert.equal(animated.materialState[0].texture, "sign-b.png")
  Assert.equal(animated.materialState[0].alphaClass, "opaque")
end

-- ---- composition and policy ----

function T.no_attachments_restores_the_base_state()
  local def = texturedDefinition()
  local instance = instanceWith(def, { scrollClip(4, { 0, 0x100, 0x200, 0x300 }) })
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.near(instance.materialState[0].texMatrix[7], -0x100 / 4096, 1e-9)
  instance:stop("scroll")
  instance:evaluateMaterials()
  local state = instance.materialState[0]
  local identity = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
  Assert.equal(state.texture, "base.png")
  for i = 1, 9 do
    Assert.near(state.texMatrix[i], identity[i], 1e-9)
  end
  Assert.equal(state.alphaClass, "cutout")
end

function T.ignores_zero_ratio_attachments()
  local def = texturedDefinition()
  local instance = ModelInstance.new(definitionWith(def, { scrollClip(4, { 0, 0x100, 0x200, 0x300 }) }))
  instance:play("scroll", { ratioFx = 0 })
  instance:evaluateMaterials()
  local state = instance.materialState[0]
  local identity = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
  for i = 1, 9 do
    Assert.near(state.texMatrix[i], identity[i], 1e-9)
  end
end

function T.highest_priority_attachment_wins()
  local def = texturedDefinition()
  local low = scrollClip(4, { 0x0, 0x100, 0x200, 0x300 })
  low.name, low.id = "scrollLow", "fixture:scrollLow"
  local high = scrollClip(4, { 0x0, 0x200, 0x400, 0x600 })
  high.name, high.id = "scrollHigh", "fixture:scrollHigh"
  local instance = ModelInstance.new(definitionWith(def, { low, high }))
  instance:play("scrollHigh", { priority = 0x20 })
  instance:play("scrollLow", { priority = 0x10 })
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.near(
    instance.materialState[0].texMatrix[7],
    -0x200 / 4096,
    1e-9,
    "the higher priority clip drives the material"
  )
end

-- The evaluator consumes the attachment's PRECOMPUTED material binding:
-- the attachment carries the material-index -> track-index
-- mapping resolved at definition assembly, so evaluation never loops every
-- track looking up names.
function T.attachments_carry_the_precomputed_material_binding()
  local def = texturedDefinition()
  local instance = instanceWith(def, { scrollClip(4, { 0, 0x100, 0x200, 0x300 }) })
  local attachment = instance.animationState:attachments("material")[1]
  Assert.equal(type(attachment), "table")
  Assert.notNil(attachment.binding)
  Assert.deepEqual(attachment.binding.map, { wall = 0 })
  Assert.deepEqual(attachment.binding.trackByMaterial, { [0] = 0 })
end

-- Equal-priority ties resolve to the LAST attached attachment: attachment
-- order IS significant to the selection (the comment claiming otherwise is
-- wrong), so the contract pins the tie behavior.
function T.equal_priority_ties_resolve_to_the_last_attached()
  local def = texturedDefinition()
  local first = scrollClip(4, { 0x0, 0x100, 0x200, 0x300 })
  first.name, first.id = "scrollFirst", "fixture:scrollFirst"
  local last = scrollClip(4, { 0x0, 0x200, 0x400, 0x600 })
  last.name, last.id = "scrollLast", "fixture:scrollLast"
  local instance = ModelInstance.new(definitionWith(def, { first, last }))
  instance:play("scrollFirst", { priority = 0x10 })
  instance:play("scrollLast", { priority = 0x10 })
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.near(
    instance.materialState[0].texMatrix[7],
    -0x200 / 4096,
    1e-9,
    "the last-attached clip wins an equal-priority tie"
  )
end

function T.missing_variant_raises()
  local def = texturedDefinition()
  local clip = patternClip()
  clip.compiled.textureNames = { "nope.a", "sign.b" }
  local instance = ModelInstance.new(definitionWith(def, { clip }))
  instance:play("pattern")
  throwsCode("ANIM_MATERIAL_VARIANT_MISSING", function()
    instance:evaluateMaterials()
  end)
end

function T.unsupported_texture_matrix_mode_raises()
  local def = texturedDefinition({ texMtxMode = 2 })
  local instance = ModelInstance.new(def)
  throwsCode("ANIM_MATERIAL_UNSUPPORTED_TEXMTX_MODE", function()
    instance:evaluateMaterials()
  end)
end

-- A material without a texture carries no UV transform and classifies on
-- its polygon state alone.
function T.untextured_material_has_no_matrix()
  local def = ModelDefinition.new({
    key = "fixture:plain",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = { { id = "m", nodeIndex = 0, materialIndex = 0, geometry = "fixtures/m.g4mesh" } },
    materials = {
      {
        id = 0,
        name = "plain",
        baseColor = { r = 255, g = 255, b = 255, a = 255 },
        alphaMode = "opaque",
        doubleSided = false,
        polygonAlpha = 31,
      },
    },
    skins = {},
    animations = {},
  })
  local instance = ModelInstance.new(def)
  instance:evaluateMaterials()
  Assert.equal(instance.materialState[0].texture, nil)
  Assert.equal(instance:effectiveMaterial(0).alphaClass, "opaque")
end

return T
