-- MapPropAnimCompiler fatal diagnostics: a referenced animation resource
-- that cannot decode or compile is an explicit fatal diagnostic identifying
-- the model member and resource -- never a silent
-- fallback that drops the clip and compiles the model static. NSBVA was
-- deleted (the HGSS field archive has no VIS0 members), so every format
-- NitroAnimation decodes has a clip compiler and a broken resource surfaces
-- as MAP_PROP_ANIM_UNRESOLVED.

local Assert = require("tests.support.Assert")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local Errors = require("libs.errors.src.Errors")
local AnimationFixture = require("tests.support.AnimationFixture")
local MapPropAnimCompiler = require("romdump.src.digest.MapPropAnimCompiler")

local T = {}

local function resNarc(members)
  return {
    readMember = function(_, memberId)
      local bytes = assert(members[memberId], "no resource member " .. memberId)
      return bytes
    end,
  }
end

-- An anim-list record whose resource ids reference the given members: the
-- 8-byte header (first u16 not 0xFFFF = the model has animations) followed
-- by four u32 id slots.
local function referencingRecord(ids)
  local bw = BinaryWriter.new()
  bw:u16(0)
  bw:u16(0)
  bw:u32(0)
  for _, id in ipairs(ids) do
    bw:u32(id)
  end
  for _ = 1, 4 - #ids do
    bw:u32(0xFFFFFFFF)
  end
  assert(#bw:tostring() == 0x18)
  return bw:tostring()
end

local function throwsCode(code, fn)
  local ok, err = pcall(fn)
  Assert.isFalse(ok, "expected error " .. code)
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(err.code, code)
  return err
end

function T.unresolved_resource_is_an_explicit_diagnostic()
  -- A referenced member that fails to decode: the compile raises with the
  -- model member and resource in context.
  local res = resNarc({ [1] = "not a nitro animation file" })
  local err = throwsCode("MAP_PROP_ANIM_UNRESOLVED", function()
    return MapPropAnimCompiler.compile(referencingRecord({ 1 }), res, {
      archiveAlias = "exterior_build_anim_list",
      memberId = 26,
    })
  end)
  Assert.equal(err.context.resourceId, 1)
  Assert.equal(err.context.memberId, 26)
  Assert.equal(err.context.archiveAlias, "exterior_build_anim_list")
end

function T.compile_returns_only_clips()
  -- The unresolved-return contract is gone: a healthy compile returns clips.
  local res = resNarc({ [1] = AnimationFixture.jntDoor() })
  local result = MapPropAnimCompiler.compile(referencingRecord({ 1 }), res, {
    archiveAlias = "exterior_build_anim_list",
    memberId = 26,
  })
  Assert.equal(#result.clips, 1)
  Assert.isNil(result.unresolved, "no silent-fallback channel remains")
end

function T.compiling_a_broken_resource_through_the_map_compile_is_fatal()
  -- The same guarantee at the full map-compile boundary: a fixture ROM whose
  -- anim-list record references a garbage resource compiles to an explicit
  -- structured error, not to a silently static model.
  local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
  local MapRomFixture = require("tests.support.MapRomFixture")
  local romFs = MapRomFixture.build({
    interiorBuildAnimList = { [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = referencingRecord({ 0 }) },
    buildAnim = { [0] = "garbage resource bytes" },
  })
  local bundle, err = MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL)
  Assert.isNil(bundle, "a broken animation resource must fail the compile")
  Assert.isTrue(Errors.is(err), "expected a structured error")
  err = assert(err)
  Assert.equal(err.code, "MAP_PROP_ANIM_UNRESOLVED")
  Assert.equal(err.context.memberId, MapRomFixture.BUILDING_MODEL_MEMBER_ID)
end

-- Fault injection at the clip-compiler seam: only a typed data error (a
-- malformed resource the clip compiler rejects) is the resource-resolution
-- diagnostic; a programming fault is not -- it propagates loudly as itself
-- so a real compiler bug is never misreported as corrupt ROM data.
local function withClipCompilerStub(impl, fn)
  local mod = require("romdump.src.digest.NsbcaClipCompiler")
  local original = mod.compile
  mod.compile = impl
  local ok, err = pcall(fn)
  mod.compile = original
  return ok, err
end

function T.a_programming_fault_in_a_clip_compiler_propagates()
  local res = resNarc({ [1] = AnimationFixture.jntDoor() })
  local ok, err = withClipCompilerStub(function()
    error("injected clip-compiler bug")
  end, function()
    return MapPropAnimCompiler.compile(referencingRecord({ 1 }), res, {
      archiveAlias = "exterior_build_anim_list",
      memberId = 26,
    })
  end)
  Assert.isFalse(ok, "a programming fault must fail the compile")
  Assert.isFalse(Errors.is(err), "a compiler bug must not masquerade as an unresolved resource")
  Assert.isTrue(tostring(err):find("injected clip-compiler bug", 1, true) ~= nil, "the original fault surfaces")
end

function T.a_typed_data_error_from_a_clip_compiler_is_the_resource_diagnostic()
  local res = resNarc({ [1] = AnimationFixture.jntDoor() })
  local ok, err = withClipCompilerStub(function()
    Errors.raise("NSBCA_CURVE_LIMIT_MISMATCH", "injected malformed channel data", {})
  end, function()
    return MapPropAnimCompiler.compile(referencingRecord({ 1 }), res, {
      archiveAlias = "exterior_build_anim_list",
      memberId = 26,
    })
  end)
  Assert.isFalse(ok)
  Assert.isTrue(Errors.is(err), "a typed data error is the structured diagnostic")
  err = assert(err)
  Assert.equal(err.code, "MAP_PROP_ANIM_UNRESOLVED")
  Assert.equal(err.context.resourceId, 1)
  Assert.equal(err.context.memberId, 26)
end

return { tests = T }
