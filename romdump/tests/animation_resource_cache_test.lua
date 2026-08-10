-- AnimationResourceCache: the per-build-run memo of compiled animation
-- resources. The same shared build_anim member (a/1/0/6) is referenced by
-- many models and every map that places them; with a cache threaded through
-- the compile, each (archive, memberId, sha1) tuple is decoded and compiled
-- once per build run and every model descriptor embeds the same record.
-- Without a cache the compile stays as before (fresh records per call).

local Assert = require("tests.support.Assert")
local BinaryWriter = require("libs.rom.src.BinaryWriter")
local AnimationFixture = require("tests.support.AnimationFixture")
local MapPropAnimCompiler = require("romdump.src.digest.MapPropAnimCompiler")
local AnimationResourceCache = require("romdump.src.digest.AnimationResourceCache")

local T = {}

-- A 0x18-byte anim-list record referencing the given resource ids.
local function listRecord(ids)
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

-- The shared animation archive as a map of memberId -> bytes.
local function resNarc(members)
  return {
    readMember = function(_, memberId)
      local bytes = assert(members[memberId], "no resource member " .. memberId)
      return bytes
    end,
  }
end

local function compile(listBytes, res, opts)
  return MapPropAnimCompiler.compile(listBytes, res, {
    archiveAlias = "exterior_build_anim_list",
    memberId = 26,
    resourceCache = opts and opts.resourceCache,
  })
end

function T.repeated_compiles_share_one_cached_record()
  local cache = AnimationResourceCache.new()
  local res = resNarc({ [1] = AnimationFixture.jntDoor() })
  local first = compile(listRecord({ 1 }), res, { resourceCache = cache })
  local second = compile(listRecord({ 1 }), res, { resourceCache = cache })
  Assert.equal(#first.clips, 1)
  Assert.equal(#second.clips, 1)
  Assert.isTrue(first.clips[1] == second.clips[1], "the cached clip record is shared by identity")
end

function T.without_a_cache_compiles_fresh_records()
  local res = resNarc({ [1] = AnimationFixture.jntDoor() })
  local first = compile(listRecord({ 1 }), res)
  local second = compile(listRecord({ 1 }), res)
  Assert.isFalse(first.clips[1] == second.clips[1], "no cache means independent records")
  Assert.equal(first.clips[1].name, second.clips[1].name)
end

function T.cache_is_keyed_by_resource_bytes()
  local cache = AnimationResourceCache.new()
  local res = resNarc({ [1] = AnimationFixture.jntDoor() })
  local first = compile(listRecord({ 1 }), res, { resourceCache = cache })
  -- Same member id, different bytes (a different resource): a fresh record.
  local res2 = resNarc({ [1] = AnimationFixture.jntFull() })
  local second = compile(listRecord({ 1 }), res2, { resourceCache = cache })
  Assert.isFalse(first.clips[1] == second.clips[1])
  Assert.equal(first.clips[1].name, "door_op")
  Assert.equal(second.clips[1].name, "full")
end

function T.cache_is_keyed_by_archive_alias()
  local cache = AnimationResourceCache.new()
  local res = resNarc({ [1] = AnimationFixture.jntDoor() })
  local exterior = compile(listRecord({ 1 }), res, { resourceCache = cache })
  local interior = MapPropAnimCompiler.compile(listRecord({ 1 }), res, {
    archiveAlias = "interior_build_anim_list",
    memberId = 26,
    resourceCache = cache,
  })
  Assert.isFalse(exterior.clips[1] == interior.clips[1])
  Assert.equal(exterior.clips[1].id, "exterior_build_anim_list-1")
  Assert.equal(interior.clips[1].id, "interior_build_anim_list-1")
end

function T.cache_returns_nil_for_unknown_keys()
  local cache = AnimationResourceCache.new()
  Assert.isNil(cache:get("no:such:key"))
end

function T.cache_holds_one_record_per_key()
  local cache = AnimationResourceCache.new()
  local res = resNarc({ [1] = AnimationFixture.jntDoor() })
  local clips = compile(listRecord({ 1 }), res, { resourceCache = cache }).clips
  local viaGet = cache:get("exterior_build_anim_list:1:" .. assert(clips[1].source.sha1))
  Assert.isTrue(viaGet == clips[1])
end

function T.compile_version_is_exposed()
  Assert.equal(type(MapPropAnimCompiler.VERSION), "string")
  Assert.isTrue(#MapPropAnimCompiler.VERSION > 0)
end

return T
