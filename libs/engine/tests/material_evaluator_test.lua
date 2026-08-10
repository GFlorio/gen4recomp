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
-- rotation.
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
            scaleS = { source = "absent" },
            scaleT = { source = "absent" },
            rot = { source = "absent" },
            transS = { source = "curve", rate = 1, limit = frames - 1, storage = "fx32", keys = transKeys },
            transT = { source = "absent" },
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
    sourceBackend = "nitro",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = { { id = "sign", nodeIndex = 0, materialIndex = 0, batch = { vertices = {}, indices = {} } } },
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
    sourceBackend = def.sourceBackend,
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

-- A 4-frame scroll animating the translation S (the Maya convention's
-- scroll channel -- the real `wind` clip animates transS): the matrix
-- translation must advance by exactly one texel per frame.
function T.scrolling_uv_advances_one_texel_per_frame()
  local def = texturedDefinition()
  local clip = scrollClip(4, { 0x0, 0x100, 0x200, 0x300 })
  local instance = instanceWith(def, { clip })
  local s0 = instance.materialState[0]
  Assert.near(s0.texMatrix[7], 0, 1e-9)
  -- c20 = -transS * w * 16 (the translation-only cells); m02 =
  -- c20 / (4096 * w) = -transS / 256, so a translation of 0x100 moves one
  -- texel.
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.near(instance.materialState[0].texMatrix[7], -0x100 / 256, 1e-9)
  instance:updateFixed()
  instance:evaluateMaterials()
  Assert.near(instance.materialState[0].texMatrix[7], -0x200 / 256, 1e-9)
  -- The texture does not change: same texture key and dimensions.
  Assert.equal(instance.materialState[0].texture, "base.png")
  Assert.equal(instance.materialState[0].texWidth, 64)
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
            transS = { source = "absent" },
            transT = { source = "absent" },
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
            scaleS = { source = "absent" },
            scaleT = { source = "absent" },
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
  Assert.near(instance.materialState[0].texMatrix[7], -0x100 / 256, 1e-9)
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
    -0x200 / 256,
    1e-9,
    "the higher priority clip drives the material"
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
    sourceBackend = "nitro",
    nodes = {
      {
        index = 0,
        name = "root",
        translation = { x = 0, y = 0, z = 0 },
        rotation = { 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale = { x = 1, y = 1, z = 1 },
      },
    },
    meshes = { { id = "m", nodeIndex = 0, materialIndex = 0, batch = { vertices = {}, indices = {} } } },
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
