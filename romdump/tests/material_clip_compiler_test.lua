-- Cross-check tests for the compiled material clip pipeline (NSBTA/NSBTP/
-- NSBMA): a decoded resource compiled by the Nsb*ClipCompiler modules and
-- sampled by the engine's CompiledNsb*Sampler modules must be identical to
-- the raw decoders' samplers, for every fixture and every frame. This is
-- the lockstep invariant between the two sides, the material equivalent of
-- the NSBCA cross-check.

local Assert = require("tests.support.Assert")
local BinaryReader = require("libs.codec.src.BinaryReader")
local NitroAnimation = require("romdump.src.digest.nitro.NitroAnimation")
local Nsbta = require("romdump.src.digest.nitro.Nsbta")
local Nsbtp = require("romdump.src.digest.nitro.Nsbtp")
local Nsbma = require("romdump.src.digest.nitro.Nsbma")
local NsbtaClipCompiler = require("romdump.src.digest.NsbtaClipCompiler")
local NsbtpClipCompiler = require("romdump.src.digest.NsbtpClipCompiler")
local NsbmaClipCompiler = require("romdump.src.digest.NsbmaClipCompiler")
local CompiledNsbtaSampler = require("libs.engine.src.CompiledNsbtaSampler")
local CompiledNsbtpSampler = require("libs.engine.src.CompiledNsbtpSampler")
local CompiledNsbmaSampler = require("libs.engine.src.CompiledNsbmaSampler")

local T = {}

-- Decode a fixture file and compile its first animation through the compiler
-- matching the decoded format.
local function compileClip(bytes)
  local decoded = assert(NitroAnimation.decode(bytes))
  local anim = assert(decoded.animations[1])
  local reader = BinaryReader.new(decoded.bytes, "sec")
  local opts = { id = "fixture:" .. anim.name, name = anim.name }
  if decoded.format == "NSBTA" then
    return anim.resource, reader, NsbtaClipCompiler.compile(anim.resource, reader, #decoded.bytes, opts)
  elseif decoded.format == "NSBTP" then
    return anim.resource, reader, NsbtpClipCompiler.compile(anim.resource, opts)
  end
  return anim.resource, reader, NsbmaClipCompiler.compile(anim.resource, reader, #decoded.bytes, opts)
end

-- ---- NSBTA ----

-- Sample both paths at every whole and half frame and require identical
-- results (values, "one" flags, rotation).
local function assertIdenticalSrt(bytes, name, opts)
  opts = opts or {}
  local resource, reader, clip = compileClip(bytes)
  Assert.equal(clip.frameCount, resource.numFrame)
  Assert.equal(clip.category, "material")
  Assert.equal(clip.kind, "texsrt")
  Assert.equal(#clip.tracks, resource.numTargets)

  local frames = {}
  for f = 0, resource.numFrame - 1 do
    frames[#frames + 1] = f * 4096
  end
  for f = 0, resource.numFrame - 1 do
    frames[#frames + 1] = f * 4096 + 2048
  end
  for _, targetIndex in ipairs(opts.targets or { 0 }) do
    for _, frameFx in ipairs(frames) do
      local expected = Nsbta.sample(reader, resource, targetIndex, frameFx)
      local actual = CompiledNsbtaSampler.sample(clip, targetIndex, frameFx)
      local label = string.format("%s target %d frame %d", name, targetIndex, frameFx / 4096)
      Assert.equal(actual.transS, expected.transS, label .. " transS")
      Assert.equal(actual.transT, expected.transT, label .. " transT")
      Assert.equal(actual.scaleS, expected.scaleS, label .. " scaleS")
      Assert.equal(actual.scaleT, expected.scaleT, label .. " scaleT")
      Assert.equal(actual.transOne, expected.transOne, label .. " transOne")
      Assert.equal(actual.rotOne, expected.rotOne, label .. " rotOne")
      Assert.equal(actual.scaleOne, expected.scaleOne, label .. " scaleOne")
      if expected.rot then
        Assert.equal(actual.rot.sin, expected.rot.sin, label .. " rot.sin")
        Assert.equal(actual.rot.cos, expected.rot.cos, label .. " rot.cos")
      end
    end
  end
end

T.srt_water_channels = function()
  return assertIdenticalSrt(require("tests.support.AnimationFixture").srtWater(), "srtWater")
end
T.srt_spin_rotation = function()
  return assertIdenticalSrt(require("tests.support.AnimationFixture").srtSpin(), "srtSpin")
end
T.srt_constant_rotation = function()
  return assertIdenticalSrt(require("tests.support.AnimationFixture").srtConstRot(), "srtConstRot")
end

function T.srt_clip_envelope()
  local _, _, clip = compileClip(require("tests.support.AnimationFixture").srtSpin())
  Assert.equal(clip.name, "spin")
  Assert.equal(clip.source.type, "nitro")
  Assert.equal(clip.source.format, "NSBTA")
  Assert.equal(clip.tracks[1].target, "en_sp1_3") -- the material name binds
  Assert.equal(clip.compiled.targets[1].name, "en_sp1_3")
end

-- ---- NSBTP ----

function T.btp_key_selection_identical()
  local resource, _, clip = compileClip(require("tests.support.AnimationFixture").patPcMb())
  Assert.equal(clip.kind, "pattern")
  Assert.equal(clip.frameCount, resource.numFrame)
  Assert.deepEqual(clip.compiled.textureNames, resource.textureNames)
  Assert.deepEqual(clip.compiled.paletteNames, resource.paletteNames)
  for f = 0, resource.numFrame - 1 do
    for h = 0, 1 do
      local frameFx = f * 4096 + h * 2048
      local expected = Nsbtp.keyAt(resource, 0, f)
      local actual = CompiledNsbtpSampler.keyAt(clip, 0, frameFx)
      local label = string.format("pc_mb frame %d", f)
      Assert.equal(actual.frame, expected.frame, label)
      Assert.equal(actual.texIdx, expected.texIdx, label .. " tex")
      Assert.equal(actual.plttIdx, expected.plttIdx, label .. " pltt")
    end
  end
end

-- ---- NSBMA ----

function T.bma_colors_and_alpha_identical()
  local resource, reader, clip = compileClip(require("tests.support.AnimationFixture").matFade())
  Assert.equal(clip.kind, "color")
  Assert.equal(clip.frameCount, resource.numFrame)
  for f = 0, resource.numFrame - 1 do
    for h = 0, 1 do
      local frameFx = f * 4096 + h * 2048
      local expected = Nsbma.sample(reader, resource, 0, frameFx)
      local actual = CompiledNsbmaSampler.sample(clip, 0, frameFx)
      local label = string.format("matFade frame %d", f)
      for _, name in ipairs({ "diffuse", "ambient", "specular", "emission", "alpha" }) do
        Assert.equal(actual[name], expected[name], label .. " " .. name)
      end
    end
  end
end

-- The corpus invariant holds for NSBTA curves too (the ROM census records
-- limit == numFrame for every NSBTA curve channel of the field archive), so
-- the compile path must raise NSBTA_CURVE_LIMIT_MISMATCH for a curve whose
-- limit differs, exactly like the NSBCA side.
function T.srt_curve_limit_below_num_frame_raises_at_compile()
  local decoded = assert(NitroAnimation.decode(require("tests.support.AnimationFixture").srtSpin(3)))
  local resource = decoded.animations[1].resource
  local reader = BinaryReader.new(decoded.bytes, "sec")
  local ok, err = pcall(NsbtaClipCompiler.compile, resource, reader, #decoded.bytes, {
    id = "fixture:spin",
    name = "spin",
  })
  Assert.isFalse(ok)
  Assert.equal(err.code, "NSBTA_CURVE_LIMIT_MISMATCH")
end

-- A decoded NSBTA record whose channel has no data (a nil slot or a zero
-- flag) cannot be compiled: the compiled payload has no "absent" state, and
-- the corpus census proves no real member carries one (identity components
-- are spelled as constants: scale 0x1000, rotation identity, translation 0).
function T.srt_absent_channel_raises_at_compile()
  local decoded = assert(NitroAnimation.decode(require("tests.support.AnimationFixture").srtWater()))
  local resource = decoded.animations[1].resource
  local reader = BinaryReader.new(decoded.bytes, "sec")
  local function compile()
    return NsbtaClipCompiler.compile(resource, reader, #decoded.bytes, {
      id = "fixture:en_sp1",
      name = "en_sp1",
    })
  end

  resource.targets[1].channels.scaleS = nil
  local ok, err = pcall(compile)
  Assert.isFalse(ok)
  Assert.equal(err.code, "NSBTA_COMPILE_ABSENT_CHANNEL")

  resource.targets[1].channels.scaleS = {
    source = "curve",
    ofs = 0,
    rate = 1,
    limit = 0,
    storage = "fx32",
    flagRaw = 0,
  }
  ok, err = pcall(compile)
  Assert.isFalse(ok)
  Assert.equal(err.code, "NSBTA_COMPILE_ABSENT_CHANNEL")
end

-- A decoded NSBMA record whose channel has no data (a nil slot or a zero
-- key offset) cannot be compiled: the compiled payload has no "absent"
-- state, and the corpus census proves no real member carries one.
function T.bma_absent_channel_raises_at_compile()
  local decoded = assert(NitroAnimation.decode(require("tests.support.AnimationFixture").matFade()))
  local resource = decoded.animations[1].resource
  local reader = BinaryReader.new(decoded.bytes, "sec")
  local function compile()
    return NsbmaClipCompiler.compile(resource, reader, #decoded.bytes, {
      id = "fixture:psentry_rode",
      name = "psentry_rode",
    })
  end

  resource.targets[1].channels.diffuse = nil
  local ok, err = pcall(compile)
  Assert.isFalse(ok)
  Assert.equal(err.code, "NSBMA_COMPILE_ABSENT_CHANNEL")

  resource.targets[1].channels.diffuse = { source = "curve", ofs = 0, rate = 1, limit = 0, isAlpha = false }
  ok, err = pcall(compile)
  Assert.isFalse(ok)
  Assert.equal(err.code, "NSBMA_COMPILE_ABSENT_CHANNEL")
end

return T
