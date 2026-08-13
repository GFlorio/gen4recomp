-- MaterialEvaluator: the per-frame composition of a model's effective
-- material state from its base material records and its playing material
-- attachments. Never mutates the definition; the result
-- lands in the instance's own materialState so two instances of one model
-- can animate at different frames.
--
-- Evaluation order per material:
--
--   base material
--     -> NSBMA modifications   (animated colors + polygon alpha)
--     -> NSBTA texture transform (animated texture-SRT state)
--     -> NSBTP texture selection (variant texture/palette, current dims)
--     -> effective material state
--     -> render classification
--
-- Texture-SRT: a "texsrt" attachment targeting the material replaces the
-- static SRT (the model's material texture-SRT extension) for that material
-- -- exactly how the Nitro BTA send replaces the material's matrix. The
-- matrix cells come from the model's texture-matrix convention
-- (texMtxMode), built against the CURRENT texture dimensions (the field
-- SetTexParamaters_ keeps updated when NSBTP switches textures), composed
-- into a normalized-UV 3x3 for the shader:
--
--   uv' = M . (u, v, 1),  M = D(cur)^-1 . C(varDims) . D(base)
--
-- where D(x) reconstructs texel coordinates from the compile-time UV
-- normalization against the base texture size, and C is the convention's
-- six cells: the linear terms are 1.3.12 fixed point, the translation
-- terms are 1.11.4 TEXCOORD fixed point (an extra /16 over the linear
-- cells, matching the decoder and the conventions' <<4 factors).
--
-- Pattern selection: a "pattern" attachment's active key selects the
-- texture/palette variant by name (the variant list the compiler resolved
-- from the model's texture set). The effective alpha class is recomputed
-- from the selected texture's format/alpha usage and the effective polygon
-- alpha before the render queue is built.
--
-- When several attachments of one kind play, each target material is driven
-- by the highest-priority attachment whose clip binds to it; ties resolve to
-- the last attached. An attachment that targets disjoint materials never
-- suppresses another attachment's materials (Nitro carries at most one
-- animation per kind per object, so real assets never stack these, but the
-- selection is per target material, not per kind). Attachments with a
-- non-positive ratio are ignored. Pure domain module.

local Errors = require("libs.errors.src.Errors")
local FixedPoint = require("libs.math.src.FixedPoint")
local AlphaClassifier = require("libs.assets.src.AlphaClassifier")
local AnimationClip = require("libs.assets.src.AnimationClip")
local NitroTexMatrix = require("libs.engine.src.NitroTexMatrix")
local CompiledNsbtaSampler = require("libs.engine.src.CompiledNsbtaSampler")
local CompiledNsbtpSampler = require("libs.engine.src.CompiledNsbtpSampler")
local CompiledNsbmaSampler = require("libs.engine.src.CompiledNsbmaSampler")

local MaterialEvaluator = {}

-- The texture-matrix conventions by model texMtxMode. Modes 2 and 3 (3ds
-- Max, XSI) have no transcribed formulas; no real HGSS field asset uses
-- them (census), so they raise rather than silently falling back.
local CONVENTIONS = {
  [0] = NitroTexMatrix.maya,
  [1] = NitroTexMatrix.si3d,
}

-- BGR555 (low 5 bits -> blue) — the NSBMA packed order, the OPPOSITE of
-- FixedPoint.rgb555 (low 5 bits -> red); keep this unpacking exactly.
local function rgb555To8(value)
  local r = math.floor(value / 1024) % 32
  local g = math.floor(value / 32) % 32
  local b = value % 32
  return {
    r = FixedPoint.rgb5ToByte(r),
    g = FixedPoint.rgb5ToByte(g),
    b = FixedPoint.rgb5ToByte(b),
  }
end

-- The track of `attachment` whose precomputed binding maps onto
-- `materialIndex`, or nil: the binding carries the material-index ->
-- track-index mapping resolved at definition assembly, so evaluation never
-- loops every track looking names up.
local function trackForMaterial(attachment, materialIndex)
  local trackIndex = attachment.binding.trackByMaterial[materialIndex]
  if trackIndex == nil then
    return nil
  end
  return attachment.clip.tracks[trackIndex + 1]
end

-- Pick the winning attachment of one kind for a single target material: the
-- highest priority whose clip actually binds to the material, ties to the
-- last attached (the attachment list is in attach order). Non-positive
-- ratios are ignored. Returns nil when none plays for the material.
local function winnerForMaterial(attachments, kind, materialIndex)
  local best
  for _, attachment in ipairs(attachments) do
    if attachment.ratioFx > 0 and attachment.clip.kind == kind then
      if attachment.binding.trackByMaterial[materialIndex] ~= nil then
        if not best or attachment.priority >= best.priority then
          best = attachment
        end
      end
    end
  end
  return best
end

-- The per-component base colors of a material record: the optional `colors`
-- block (the dynamic compiler's four DS registers) when present, else the
-- baseColor reconstruction -- baseColor for every channel, since the shader
-- multiplies the field profile's registers by these values and a static
-- field material owns none of them (the HGSS field policy clears the four
-- color ownership bits). ModelInstance's initial material state calls the
-- same helper, so the reconstruction cannot drift between the evaluator and
-- the instance.

---@class MaterialColorComponents
---@field diffuse MaterialRGB
---@field ambient MaterialRGB
---@field specular MaterialRGB
---@field emission MaterialRGB
---@param material table
---@return MaterialColorComponents
function MaterialEvaluator.baseColors(material)
  local baseColor = material.baseColor
  local function component(name)
    local c = material.colors and material.colors[name]
    if c then
      return { r = c.r, g = c.g, b = c.b }
    end
    return { r = baseColor.r, g = baseColor.g, b = baseColor.b }
  end
  return {
    diffuse = component("diffuse"),
    ambient = component("ambient"),
    specular = component("specular"),
    emission = component("emission"),
  }
end

-- The material record of `definition` with the base material state the
-- evaluator mutates per frame. The base colors come from baseColors (the
-- per-DS-register reconstruction above); the descriptor gate guarantees the
-- baseColor and polygonAlpha fields on every dynamic material record.
local function baseMaterialState(definition, materialIndex)
  local material =
    assert(definition.materials[materialIndex + 1], "material index " .. tostring(materialIndex) .. " out of range")
  local baseColor = material.baseColor
  return {
    record = material,
    colors = MaterialEvaluator.baseColors(material),
    alpha = baseColor.a,
    polygonAlpha = material.polygonAlpha,
  }
end

-- Compose the six convention cells into the shader's normalized-UV 3x3
-- (column-major). `baseW/baseH` are the texture dimensions the mesh UVs
-- were normalized against at compile time; `curW/curH` the current
-- texture's dimensions.
--
-- The linear cells are 1.3.12 fixed point (scale 4096). The translation
-- cells live in the DS TEXCOORD domain instead: TEXCOORD coordinates are
-- 1.11.4 fixed point, the display-list decoder divides them by 16 to get
-- texels, and the convention translation folds carry the matching <<4
-- factors (NitroTexMatrix). They therefore divide by an extra 16 over the
-- linear cells: one fx32 translation unit (0x1000) is exactly one texture
-- width of normalized translation.
local function texMatrix(cells, baseW, baseH, curW, curH)
  local scale = FixedPoint.FX32_SCALE
  return {
    cells[1] * baseW / (scale * curW), -- m00: u * s
    cells[2] * baseW / (scale * curH), -- m10: v * s
    0,
    cells[3] * baseH / (scale * curW), -- m01: u * t
    cells[4] * baseH / (scale * curH), -- m11: v * t
    0,
    cells[5] / (scale * 16 * curW), -- m02: u translation (TEXCOORD)
    cells[6] / (scale * 16 * curH), -- m12: v translation (TEXCOORD)
    1,
  }
end

-- The static texture-SRT state of the material record, in the same shape
-- the compiled BTA sampler returns (with "one" flags from the presence
-- bits: an absent component is identity).
local function staticSrt(material)
  local srt = material.srt
  if not srt then
    return {
      transS = 0,
      transT = 0,
      rot = nil,
      scaleS = FixedPoint.FX32_SCALE,
      scaleT = FixedPoint.FX32_SCALE,
      transOne = true,
      rotOne = true,
      scaleOne = true,
    }
  end
  local out = {
    transS = srt.transS,
    transT = srt.transT,
    rot = srt.rot,
    scaleS = srt.scaleS,
    scaleT = srt.scaleT,
    transOne = srt.transOne,
    rotOne = srt.rotOne,
    scaleOne = srt.scaleOne,
  }
  if out.rot == nil then
    out.rotOne = true
  end
  return out
end

-- The texture variant a pattern key selects, or nil when the material has
-- no variants (no pattern animation compiled).
local function variantFor(compiled, key, material)
  local texName = compiled.textureNames[key.texIdx + 1]
  if texName == nil then
    Errors.raise(
      "ANIM_MATERIAL_VARIANT_MISSING",
      "material "
        .. tostring(material.name)
        .. " pattern key references texture index "
        .. tostring(key.texIdx)
        .. " outside the compiled texture list",
      { material = material.name, texIdx = key.texIdx }
    )
  end
  local name = texName
  if key.plttIdx ~= 0xFF then
    local plttName = compiled.paletteNames[key.plttIdx + 1]
    if plttName == nil then
      Errors.raise(
        "ANIM_MATERIAL_VARIANT_MISSING",
        "material "
          .. tostring(material.name)
          .. " pattern key references palette index "
          .. tostring(key.plttIdx)
          .. " outside the compiled palette list",
        { material = material.name, plttIdx = key.plttIdx }
      )
    end
    name = texName .. "+" .. plttName
  end
  for _, variant in ipairs(material.variants or {}) do
    if variant.name == name then
      return variant
    end
  end
  Errors.raise(
    "ANIM_MATERIAL_VARIANT_MISSING",
    "material "
      .. tostring(material.name)
      .. " has no compiled variant named "
      .. name
      .. " (referenced by pattern animation)",
    { material = material.name, variant = name }
  )
end

-- The texture metadata a material currently draws with: its base texture or
-- the variant a pattern attachment selected. Returns { texture, width,
-- height, format, alphaUsage } with nil texture for untextured materials.
local function currentTexture(material, patternAttachment, patternTrack)
  local selected
  if patternAttachment and patternTrack then
    local clip = patternAttachment.clip
    local key = CompiledNsbtpSampler.keyAt(clip, patternTrack.targetIndex, patternAttachment.player.frameFx)
    selected = variantFor(clip.compiled, key, material)
  end
  local record = selected or material
  return {
    texture = record.texture,
    width = record.texWidth or record.width,
    height = record.texHeight or record.height,
    format = record.textureFormat,
    alphaUsage = record.alphaUsage,
  }
end

-- Evaluate every material of `definition` under the material attachments
-- into `materialState` (per material index). `materialState` entries are
-- replaced wholesale; the caller's table is updated in place so the
-- instance keeps its identity.
function MaterialEvaluator.evaluate(definition, attachments, materialState)
  assert(type(definition) == "table" and definition.materials ~= nil, "MaterialEvaluator requires a model definition")
  assert(
    type(attachments) == "table" and type(materialState) == "table",
    "MaterialEvaluator requires the attachment list and the material state"
  )

  for materialIndex = 0, #definition.materials - 1 do
    local pattern = winnerForMaterial(attachments, AnimationClip.KINDS.PATTERN, materialIndex)
    local texsrt = winnerForMaterial(attachments, AnimationClip.KINDS.TEXSRT, materialIndex)
    local color = winnerForMaterial(attachments, AnimationClip.KINDS.COLOR, materialIndex)

    local baseState = baseMaterialState(definition, materialIndex)
    local material = baseState.record

    local patternTrack = pattern and trackForMaterial(pattern, materialIndex)
    local tex = currentTexture(material, pattern, patternTrack)

    -- NSBMA: the winning color attachment overrides the sampled channels;
    -- channels it does not animate keep the base material colors. A playing
    -- clip drives the whole register set (compiled clips always carry all
    -- four color channels), so `colorAnimated` marks the material for the
    -- renderer: its colors replace the field profile at the register.
    local colors = baseState.colors
    local colorAnimated = false
    if color then
      local track = trackForMaterial(color, materialIndex)
      if track then
        local sampled = CompiledNsbmaSampler.sample(color.clip, track.targetIndex, color.player.frameFx)
        colorAnimated = true
        for _, name in ipairs({ "diffuse", "ambient", "specular", "emission" }) do
          local value = sampled[name]
          if value ~= nil then
            local rgb = rgb555To8(value)
            local target = colors[name]
            target.r, target.g, target.b = rgb.r, rgb.g, rgb.b
          end
        end
        if sampled.alpha ~= nil then
          baseState.polygonAlpha = sampled.alpha
        end
      end
    end

    -- NSBTA: the winning texture-SRT attachment drives the matrix for its
    -- target materials; others keep the static SRT. The matrix is built
    -- against the current texture dimensions.
    local srt = staticSrt(material)
    if texsrt then
      local track = trackForMaterial(texsrt, materialIndex)
      if track then
        srt = CompiledNsbtaSampler.sample(texsrt.clip, track.targetIndex, texsrt.player.frameFx)
      end
    end

    local mode = material.texMtxMode
    local convention = CONVENTIONS[mode]
    if not convention then
      Errors.raise(
        "ANIM_MATERIAL_UNSUPPORTED_TEXMTX_MODE",
        "model "
          .. definition.key
          .. " material "
          .. tostring(material.name)
          .. " uses texture-matrix mode "
          .. tostring(mode)
          .. " (3ds Max / XSI), which has no compiled convention",
        { modelKey = definition.key, material = material.name, mode = mode }
      )
    end
    local baseW = material.texWidth
    local baseH = material.texHeight
    local curW = tex.width
    local curH = tex.height
    if baseW == 0 or baseH == 0 or curW == 0 or curH == 0 then
      -- Untextured materials carry no texture matrix; their class follows
      -- the model contract's alphaMode unless the record carries texture
      -- metadata (then the classifier rules apply with the material's own
      -- format, not a fabricated zero).
      local identity = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
      local alphaClass
      if material.textureFormat ~= nil then
        alphaClass = AlphaClassifier.classify(baseState.polygonAlpha, material.textureFormat, material.alphaUsage)
      end
      materialState[materialIndex] = {
        texture = nil,
        texWidth = nil,
        texHeight = nil,
        colors = colors,
        colorAnimated = colorAnimated,
        polygonAlpha = baseState.polygonAlpha,
        texMatrix = identity,
        alphaClass = alphaClass,
      }
    else
      local cells = convention({
        transS = srt.transS,
        transT = srt.transT,
        sin = srt.rot and srt.rot.sin or 0,
        cos = srt.rot and srt.rot.cos or 0,
        scaleS = srt.scaleS,
        scaleT = srt.scaleT,
        width = curW,
        height = curH,
        transOne = srt.transOne,
        rotOne = srt.rotOne,
        scaleOne = srt.scaleOne,
        ratioS = FixedPoint.FX32_SCALE,
        ratioT = FixedPoint.FX32_SCALE,
      })
      materialState[materialIndex] = {
        texture = tex.texture,
        texWidth = curW,
        texHeight = curH,
        colors = colors,
        colorAnimated = colorAnimated,
        polygonAlpha = baseState.polygonAlpha,
        texMatrix = texMatrix(cells, baseW, baseH, curW, curH),
        alphaClass = AlphaClassifier.classify(baseState.polygonAlpha, tex.format, tex.alphaUsage),
      }
    end
  end
  return materialState
end

return MaterialEvaluator
