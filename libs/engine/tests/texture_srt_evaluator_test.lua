-- TextureSrtEvaluator tests: the direct contract of the shared texture-matrix
-- composition extracted from MaterialEvaluator -- static-SRT derivation with
-- the "one" flags, the Maya mode-0-only rule, the untextured identity
-- convention, and the normalized 3x3 composition over the generated material
-- fields and an optional sampled NSBTA state. The cross-module parity (the
-- animator versus the dynamic-model evaluator) lives in
-- terrain_material_animator_test.lua; this suite pins the evaluator's own
-- boundary and its non-mutation guarantee. Pure domain; no rendering, no love.

local Assert = require("tests.support.Assert")
local TextureSrtEvaluator = require("libs.engine.src.TextureSrtEvaluator")

local T = {}

local function throwsCode(code, fn)
  local ok, result = pcall(fn)
  if ok then
    error("expected a structured " .. code .. " error, got a result")
  end
  Assert.equal(result.code, code)
end

local IDENTITY = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

local function deepCopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = deepCopy(v)
  end
  return out
end

-- A scene-form terrain material: the generated base fields the evaluator
-- consumes (texWidth/texHeight/texMtxMode and the optional static srt).
local function material(opts)
  opts = opts or {}
  return {
    id = 0,
    name = opts.name or "soil",
    texture = "soil.png",
    texWidth = opts.texWidth or 16,
    texHeight = opts.texHeight or 16,
    texMtxMode = opts.texMtxMode or 0,
    srt = opts.srt,
  }
end

local function assertMatrix(actual, expected, label)
  for i = 1, 9 do
    Assert.near(actual[i], expected[i], 1e-9, (label or "texMatrix") .. " cell " .. tostring(i))
  end
end

-- A material without an srt derives the full identity state: every "one"
-- flag set, so the Maya variant composition collapses to the identity
-- matrix.
function T.static_srt_absent_composes_identity()
  local m = TextureSrtEvaluator.matrix(material(), nil)
  assertMatrix(m, IDENTITY, "no-srt material")
end

-- A static srt without a rotation carries rotOne from the serialized
-- contract (TextureMatrixState emits the flag from the source's presence),
-- so the scaleOne+rotOne translation variant composes: on a 16px texture a
-- transS of 0x100 is a sixteenth of the normalized width (m02 == -1/16)
-- with identity linear cells.
function T.static_no_rot_composes_the_translation_variant()
  local m = TextureSrtEvaluator.matrix(
    material({
      srt = {
        scaleS = 0x1000,
        scaleT = 0x1000,
        transS = 0x100,
        transT = 0,
        scaleOne = true,
        rotOne = true,
        transOne = false,
      },
    }),
    nil
  )
  Assert.near(m[1], 1, 1e-9)
  Assert.near(m[5], 1, 1e-9)
  Assert.near(m[7], -1 / 16, 1e-9)
  Assert.near(m[8], 0, 1e-9)
  Assert.near(m[2], 0, 1e-9)
  Assert.near(m[4], 0, 1e-9)
end

-- A sampled NSBTA state replaces the static srt: the translation-TEXCOORD
-- domain means one fx32 unit of transS is exactly one normalized texture
-- width (m02 == -1), even when the static srt carried a different value.
function T.sampled_state_replaces_the_static_srt()
  local record = material({
    srt = {
      scaleS = 0x1000,
      scaleT = 0x1000,
      transS = 0x200,
      transT = 0,
      scaleOne = true,
      transOne = false,
    },
  })
  local sampled = {
    transS = 0x1000,
    transT = 0,
    rot = nil,
    scaleS = 0x1000,
    scaleT = 0x1000,
    transOne = false,
    rotOne = true,
    scaleOne = true,
  }
  local m = TextureSrtEvaluator.matrix(record, sampled)
  Assert.near(m[7], -1, 1e-9, "the sample replaces the static translation")
  Assert.near(m[1], 1, 1e-9)
  Assert.near(m[5], 1, 1e-9)
end

-- Only the Maya convention (mode 0) has a compiled transcription; any other
-- mode raises the owner-local structured error.
function T.unsupported_texmtx_modes_raise()
  throwsCode(TextureSrtEvaluator.ERROR_UNSUPPORTED_TEXMTX_MODE, function()
    TextureSrtEvaluator.matrix(material({ texMtxMode = 1 }), nil)
  end)
end

-- The untextured convention: zero dimensions compose the identity matrix
-- and ignore both the static and the sampled srt.
function T.untextured_materials_compose_identity()
  local record = material({ texWidth = 0, texHeight = 0 })
  local sampled = {
    transS = 0x1000,
    transT = 0,
    rot = nil,
    scaleS = 0x1000,
    scaleT = 0x1000,
    transOne = false,
    rotOne = true,
    scaleOne = true,
  }
  assertMatrix(TextureSrtEvaluator.matrix(record, sampled), IDENTITY, "sampled untextured")
  record.srt = {
    scaleS = 0x2000,
    scaleT = 0x2000,
    transS = 0x100,
    transT = 0,
    scaleOne = false,
    transOne = false,
  }
  assertMatrix(TextureSrtEvaluator.matrix(record, nil), IDENTITY, "static untextured")
end

-- The evaluator composes fresh runtime-owned values: neither the material
-- record nor the sampled state is mutated.
function T.matrix_does_not_mutate_its_inputs()
  local record = material({
    srt = {
      scaleS = 0x1800,
      scaleT = 0x1000,
      transS = 0x200,
      transT = 0x100,
      rot = { sin = 0x400, cos = 0xE00 },
      scaleOne = false,
      transOne = false,
      rotOne = false,
    },
  })
  local sampled = {
    transS = 0x1000,
    transT = 0x100,
    rot = { sin = 0x400, cos = 0xE00 },
    scaleS = 0x1800,
    scaleT = 0x1000,
    transOne = false,
    rotOne = false,
    scaleOne = false,
  }
  local recordCopy = deepCopy(record)
  local sampledCopy = deepCopy(sampled)
  TextureSrtEvaluator.matrix(record, sampled)
  Assert.deepEqual(record, recordCopy, "material record")
  Assert.deepEqual(sampled, sampledCopy, "sampled state")
end

return { tests = T }
