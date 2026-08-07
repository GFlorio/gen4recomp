-- Overlay-pointer discovery and deterministic exact field-camera compilation.

local Assert = require("tests.support.Assert")
local FieldCameraCompiler = require("romdump.src.digest.FieldCameraCompiler")
local FieldCameraCacheWriter = require("romdump.src.digest.FieldCameraCacheWriter")
local CacheFs = require("libs.rom.src.CacheFs")
local FakeCache = require("tests.support.FakeCache")
local LuaWriter = require("libs.rom.src.LuaWriter")
local FieldCameraInspector = require("romdump.src.digest.FieldCameraInspector")
local FieldCamera = require("libs.engine.src.FieldCamera")

local T = {}

local function u8(v) return string.char(v % 256) end
local function u16(v) return u8(v) .. u8(math.floor(v / 256)) end
local function u32(v) return u16(v) .. u16(math.floor(v / 65536)) end
local function record(projection)
  return u32(0x10000) .. u16(0) .. u16(0) .. u16(0) .. u16(0)
    .. u8(projection) .. u8(0) .. u16(0x1000)
    .. u32(0x1000) .. u32(0x2000) .. u32(0) .. u32(0) .. u32(0)
end

local function fixture(secondPointer)
  local ramAddress, tableOffset = 0x02200000, 0x20
  local tableAddress = ramAddress + tableOffset
  local bytes = string.rep("\0", 8) .. u32(tableAddress)
    .. u32(secondPointer or tableAddress) .. string.rep("\0", 16)
    .. record(0) .. record(1)
  return {
    version = function() return "heartgold" end,
    metadata = function() return { sha1 = "rom-sha" } end,
    readOverlay = function(_, cpu, overlayId)
      return bytes, { cpu = cpu, overlayId = overlayId, fileId = 7,
        path = "system/overlay9/overlay_1.bin", ramAddress = ramAddress }
    end,
  }, {
    cpu = "arm9", overlayId = 1, pointerFileOffsets = { 8, 12 },
    recordCount = 2, recordSize = 0x24,
  }
end

function T.discovers_duplicate_pointers_and_compiles_exact_count()
  local romFs, discovery = fixture()
  local bundle = assert(FieldCameraCompiler.compile(romFs, discovery,
    function() return "overlay-sha" end))
  Assert.equal(bundle.profiles.schema, "g4-field-camera-profiles-v1")
  Assert.equal(bundle.profiles.recordCount, 2)
  Assert.equal(bundle.profiles.profiles[0].projection, "perspective")
  Assert.equal(bundle.profiles.profiles[1].projection, "orthographic")
  Assert.notNil(FieldCamera.new(bundle.profiles.profiles[0]),
    "compiled profiles are directly consumable by FieldCamera")
  Assert.equal(bundle.profiles.source.tableFileOffset, 0x20)
  Assert.deepEqual(bundle.profiles.source.pointerFileOffsets, { 8, 12 })
  Assert.equal(bundle.profiles.source.overlaySha1, "overlay-sha")
  local again = assert(FieldCameraCompiler.compile(romFs, discovery,
    function() return "overlay-sha" end))
  Assert.equal(LuaWriter.encode(bundle.profiles), LuaWriter.encode(again.profiles))
end

function T.inspector_reports_profiles_without_presentation_policy()
  local romFs, discovery = fixture()
  local bundle = assert(FieldCameraCompiler.compile(romFs, discovery,
    function() return "overlay-sha" end))
  local report = FieldCameraInspector.inspect(bundle.profiles)
  Assert.equal(#report.records, 2)
  Assert.equal(report.records[1].cameraType, 0)
  Assert.equal(report.records[2].projection, "orthographic")
  Assert.isNil(report.aspect)
end

function T.rejects_disagreeing_pointers()
  local romFs, discovery = fixture(0x02200024)
  local bundle, err = FieldCameraCompiler.compile(romFs, discovery,
    function() return "overlay-sha" end)
  Assert.isNil(bundle)
  Assert.equal(assert(err).code, "FIELD_CAMERA_POINTER_MISMATCH")
end

function T.rejects_pointer_offsets_outside_overlay()
  local romFs, discovery = fixture()
  discovery.pointerFileOffsets = { 9999 }
  local bundle, err = FieldCameraCompiler.compile(romFs, discovery,
    function() return "overlay-sha" end)
  Assert.isNil(bundle)
  Assert.equal(assert(err).code, "FIELD_CAMERA_POINTER_OUT_OF_BOUNDS")
end

function T.writer_commits_marker_last_and_is_deterministic()
  local romFs, discovery = fixture()
  local bundle = assert(FieldCameraCompiler.compile(romFs, discovery,
    function() return "overlay-sha" end))
  local backend = FakeCache.new()
  local cache = CacheFs.forVersion("heartgold", backend)
  FieldCameraCacheWriter.write(cache, bundle)
  Assert.isTrue(FieldCameraCacheWriter.isReady(cache, bundle.marker))
  Assert.isFalse(FieldCameraCacheWriter.isReady(cache, bundle.marker .. "-stale"))
  Assert.equal(cache:read("data/generated/field/camera/complete"), bundle.marker)
  local first = cache:read("data/generated/field/camera/profiles.lua")
  FieldCameraCacheWriter.write(cache, bundle)
  Assert.equal(cache:read("data/generated/field/camera/profiles.lua"), first)
end

return T
