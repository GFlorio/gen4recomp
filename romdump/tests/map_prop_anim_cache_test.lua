-- MapPropAnimCompiler's shared animation-resource cache through the full map
-- compile: one PLAIN memo table across a build run (the CLI Runner passes {};
-- there is no AnimationResourceCache class). Each (archive, resource member,
-- sha1) tuple decodes and compiles exactly once per cache, and every model
-- that references it embeds a per-model SHALLOW COPY of the compiled record
-- -- equal content, never identity-shared -- so the per-model policy
-- annotation (timeBand/ambientLoop) can never mutate the record other models
-- share. Synthetic: MapRomFixture builds two maps whose anim-list records
-- reference the SAME fixture resource bytes, so the sha1 cache keys collide
-- exactly like the real New Bark / Route 12 door pair. Split out of the
-- ROM-gated tests/rom golden smoke so a fixture change cannot ripple through
-- the real-dump file.

local Assert = require("tests.support.Assert")
local BinaryWriter = require("libs.codec.src.BinaryWriter")
local Hashing = require("romdump.src.digest.Hashing")
local AnimationFixture = require("tests.support.AnimationFixture")
local MapAssetCompiler = require("romdump.src.digest.MapAssetCompiler")
local MapRomFixture = require("tests.support.MapRomFixture")

local T = {}

-- An anim-list record whose resource ids reference the given build_anim
-- members (0x18-byte slot; header shape per BuildModelAnimList).
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

-- The shared resource bytes BOTH map fixtures reference (the synthetic twin
-- of the real door pair build_anim members 1/2): the cache key embeds the
-- resource sha1, so the two maps must reference identical bytes.
local function sharedResources()
  return { [0] = AnimationFixture.jntDoor(), [1] = AnimationFixture.jntFull() }
end

-- One fixture map whose building model references the given resource subset.
local function mapWith(ids)
  return MapRomFixture.build({
    interiorBuildAnimList = { [MapRomFixture.BUILDING_MODEL_MEMBER_ID] = referencingRecord(ids) },
    buildAnim = sharedResources(),
  })
end

local function compile(romFs, cache)
  return assert(MapAssetCompiler.compile(romFs, MapRomFixture.MAP_SYMBOL, { resourceCache = cache }))
end

-- Snapshot the memo's records (key -> record) to prove later compiles
-- reuse them by identity.
local function memoSnapshot(memo)
  local snap = {}
  for key, record in pairs(memo) do
    snap[key] = record
  end
  return snap
end

local function memoCount(memo)
  local n = 0
  for _ in pairs(memo) do
    n = n + 1
  end
  return n
end

-- After more compiles, every memo record must still be the SAME object a
-- previous compile stored: a recompile would overwrite its key with a
-- fresh record, breaking identity. The key set must be unchanged too.
local function assertMemoReused(memo, snap, label)
  Assert.equal(memoCount(memo), memoCount(snap), label .. ": no new records")
  for key, record in pairs(memo) do
    Assert.isTrue(snap[key] == record, label .. ": " .. key .. " reused by identity")
  end
end

-- The observable compiled content of a clip: per-model records must agree
-- on everything except the per-model policy annotations (timeBand/
-- ambientLoop) the compiler stamps on each copy.
local function assertClipContentEqual(a, b, label)
  Assert.equal(a.id, b.id, label .. " id")
  Assert.equal(a.name, b.name, label .. " name")
  Assert.equal(a.category, b.category, label .. " category")
  Assert.equal(a.kind, b.kind, label .. " kind")
  Assert.equal(a.frameCount, b.frameCount, label .. " frame count")
  Assert.deepEqual(a.tracks, b.tracks, label .. " tracks")
  Assert.deepEqual(a.semanticNames, b.semanticNames, label .. " roles")
  Assert.deepEqual(a.source, b.source, label .. " source")
end

local function descriptorOf(bundle)
  for _, desc in pairs(bundle.models) do
    if desc.memberId == MapRomFixture.BUILDING_MODEL_MEMBER_ID then
      return desc
    end
  end
  return nil
end

local function clipOf(desc, name)
  for _, clip in ipairs(desc.animations) do
    if clip.name == name then
      return clip
    end
  end
  return nil
end

-- The animation resource cache: one map's model references two shared
-- resources and a second map's model references a subset of them. The
-- production memo is shared across a build run: each (archive, resource
-- member, sha1) tuple decodes and compiles exactly once per cache, and
-- every model that references it embeds a per-model SHALLOW COPY of the
-- compiled record -- equal content, never identity-shared -- so the
-- per-model policy annotation (timeBand/ambientLoop) can never mutate the
-- record other models share.
function T.shared_cache_dedups_clip_records_across_map_builds()
  local cache = {}
  local bundleA = compile(mapWith({ 0, 1 }), cache)
  local afterA = memoSnapshot(cache)
  Assert.equal(memoCount(afterA), 2, "the map references two unique animation resources")

  -- The second map's resources are a subset of the first's (the door pair
  -- alone), so the shared cache compiles nothing new: both records are
  -- still the same objects the first compile stored.
  local bundleB = compile(mapWith({ 0 }), cache)
  assertMemoReused(cache, afterA, "the subset map reuses the shared records")

  -- A warm second compile of the same map adds nothing: every record is
  -- still the same object, so nothing decoded or compiled twice.
  compile(mapWith({ 0 }), cache)
  assertMemoReused(cache, afterA, "a warm second compile reuses every record")

  -- A fresh memo (a separate build run) compiles the subset's own resource
  -- again: the dedup is per build run, and its records are independent
  -- objects.
  local freshCache = {}
  local fresh = compile(mapWith({ 0 }), freshCache)
  Assert.equal(memoCount(freshCache), 1, "the subset's own resource compiles fresh")

  -- Content addressing: the animation list and the clip resources are in
  -- the dependency record, so a changed animation invalidates the compile.
  Assert.isTrue(#bundleA.dependencies.animationListMemberSha1s > 0)

  local descA, descB = descriptorOf(bundleA), descriptorOf(bundleB)
  local freshDesc = descriptorOf(fresh)
  assert(descA and descA.dynamic, "the animated descriptor compiles through the dynamic path")
  assert(descB and descB.dynamic, "the subset descriptor compiles through the dynamic path")
  Assert.equal(#descA.animations, 2)
  Assert.equal(#descB.animations, 1)
  local doorOpA, doorOpB = clipOf(descA, "door_op"), clipOf(descB, "door_op")
  local freshClip = clipOf(freshDesc, "door_op")
  assert(doorOpA and doorOpB and freshClip, "the door clip compiles in every build")

  -- Per-model clip records: equal compiled content, never identity-shared
  -- (each model embeds its own copy, so its policy annotation cannot
  -- mutate the record other models share).
  Assert.isFalse(doorOpA == doorOpB, "door_op is a per-model copy, not a shared record")
  assertClipContentEqual(doorOpA, doorOpB, "door_op")

  -- Provenance: the clip's sha1 is the resource bytes the memo key was
  -- built from, preserved through the memo and every per-model copy.
  Assert.equal(
    doorOpA.source.sha1,
    Hashing.sha1hex(assert(sharedResources()[doorOpA.source.memberId])),
    "door_op provenance sha1 is the resource bytes"
  )

  -- A separate build run compiles an independent record with equal content.
  Assert.isFalse(freshClip == doorOpA, "a fresh memo compiles fresh records")
  assertClipContentEqual(freshClip, doorOpA, "door_op")
end

return T
