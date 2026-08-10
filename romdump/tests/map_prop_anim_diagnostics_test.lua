-- MapPropAnimCompiler fatal diagnostics: a referenced animation resource
-- that cannot decode or compile is an explicit fatal diagnostic identifying
-- the model member and resource (spec sections 29 + 39) -- never a silent
-- fallback that drops the clip and compiles the model static. NSBVA is the
-- honest unsupported case: it has a decoder but no clip compiler, so a VIS0
-- resource in an anim-list record raises MAP_PROP_ANIM_UNSUPPORTED_FORMAT.

local Assert = require("tests.support.Assert")
local BinaryWriter = require("libs.rom.src.BinaryWriter")
local Errors = require("libs.rom.src.Errors")
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

function T.unsupported_format_is_an_explicit_diagnostic()
  -- NSBVA decodes (the decoder exists) but has no clip compiler: compiling a
  -- VIS0 resource must raise, never drop the clip.
  local res = resNarc({ [1] = AnimationFixture.visSimple() })
  local err = throwsCode("MAP_PROP_ANIM_UNSUPPORTED_FORMAT", function()
    return MapPropAnimCompiler.compile(referencingRecord({ 1 }), res, {
      archiveAlias = "exterior_build_anim_list",
      memberId = 26,
    })
  end)
  Assert.equal(err.context.memberId, 1, "context identifies the resource member")
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

function T.unsupported_format_through_the_map_compile_is_fatal()
  local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
  local MapRomFixture = require("tests.support.MapRomFixture")
  local romFs = MapRomFixture.build({
    interiorBuildAnimList = { [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = referencingRecord({ 0 }) },
    buildAnim = { [0] = AnimationFixture.visSimple() },
  })
  local bundle, err = MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL)
  Assert.isNil(bundle, "an unsupported animation format must fail the compile")
  Assert.isTrue(Errors.is(err), "expected a structured error")
  Assert.equal(assert(err).code, "MAP_PROP_ANIM_UNSUPPORTED_FORMAT")
end

return T
