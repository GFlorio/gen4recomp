-- MapPropAnimCompiler: resolves a map-prop model's animation records (a
-- member of the exterior/interior build-anim-list archive, HGSS a/1/0/7 and
-- a/1/0/8) into compiled animation clips for the model descriptor. Each
-- record's resource ids index the shared animation archive (a/1/0/6), whose
-- members are any of the five Nitro animation formats; the matching decoder
-- is dispatched by format and compiled by the matching clip compiler, so the
-- runtime never touches Nitro animation bytes.
--
-- A referenced resource that cannot decode or compile is an EXPLICIT FATAL
-- diagnostic -- MAP_PROP_ANIM_UNRESOLVED / MAP_PROP_ANIM_UNSUPPORTED_FORMAT,
-- identifying the model member and resource, with every compiler failure
-- converted to the same code. Nothing returns an unresolved entry and falls
-- back to compiling the model static: the animation either compiles or the
-- map compile fails loudly.
--
-- Semantic roles: clip names are the source-format identifiers; gameplay
-- must not depend on them. The door open/close pairs the field corpus uses
-- are mapped onto the door.open/door.close roles by name pattern:
--
--   *door_op  -> door.open    *door_cl  -> door.close
--   *door_mop -> door.open    *door_mcl -> door.close
--
-- Every other clip keeps its name as the addressable id (prop.play("wind")).
-- Playback policy is compiled from the decoded anim-list header
-- (BuildModelAnimList), never inferred at runtime. The ordinary registrar
-- (ov01_021E8F3C) registers and plays EVERY id slot of a record whose header
-- is registration=1, policy=0 (both bits clear), control=0 (the
-- never-finishing forward loop state, ov01_022044C8(-1, 0, 0)), areaGate=0
-- -- so every clip of such a record is stamped clip.ambientLoop, and no clip
-- of any other record is. A banded record (policy 0x08) carries up to four
-- clips in the game's band-slot order -- MORN=0, DAY=1, EVE=2, NITE=3 (band
-- map ov01_022095EC) -- and each clip is stamped with the time band of its
-- slot, exactly the array the game swaps on RTC time-of-day changes
-- (ov01_022047DC). Clip names are authoring labels, not band claims: banded
-- props name their states freely (kk_sky_m/d/e/n, si_light_m1/m2,
-- time_anime1..4), so no name convention is consulted. The mapping is a
-- compile-time policy decision, not a runtime assumption. Pure domain module.

local BinaryReader = require("libs.rom.src.BinaryReader")
local Errors = require("libs.rom.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local NitroAnimation = require("romdump.src.digest.nitro.NitroAnimation")
local NsbcaClipCompiler = require("romdump.src.digest.NsbcaClipCompiler")
local NsbtaClipCompiler = require("romdump.src.digest.NsbtaClipCompiler")
local NsbtpClipCompiler = require("romdump.src.digest.NsbtpClipCompiler")
local NsbmaClipCompiler = require("romdump.src.digest.NsbmaClipCompiler")

local MapPropAnimCompiler = {}

-- The shared animation archive both build-anim lists reference (HGSS a/1/0/6).
local ANIM_ARCHIVE = "build_anim"

-- Version of the animation decode + clip-compile semantics. Cache keys of
-- compiled assets must account for it: a decoder or sampler change without
-- it would leave stale compiled clips in the derived cache. Bump whenever
-- the decoders or the clip compilers change behavior.
MapPropAnimCompiler.VERSION = "map-prop-anim-clip-v5"

-- clip name -> semantic role. Patterns match the tail of the Nitro dict
-- name; the whole name matches when the pattern is exact. The role
-- vocabulary lives on the animation contract (AnimationClip.ROLES), the one
-- owner compiler and runtime share -- the digest never depends
-- on a runtime controller.
local AnimationClip = require("libs.engine.src.AnimationClip")

local ROLE_PATTERNS = {
  door_op = AnimationClip.ROLES.DOOR_OPEN,
  door_cl = AnimationClip.ROLES.DOOR_CLOSE,
  door_mop = AnimationClip.ROLES.DOOR_OPEN,
  door_mcl = AnimationClip.ROLES.DOOR_CLOSE,
}

-- The semantic role for a clip name, or nil (the clip keeps its name).
function MapPropAnimCompiler.roleFor(name)
  for pattern, role in pairs(ROLE_PATTERNS) do
    if name == pattern or name:sub(-#pattern) == pattern then
      return role
    end
  end
  return nil
end

-- The four band slots in the game's band-map order (ov01_022095EC: MORN=0,
-- DAY=1, EVE=2, NITE=3, LATE=3). A banded anim-list record's ids are these
-- slots in order; the slot, not the clip name, is the band.
local BAND_BY_SLOT = { "morn", "day", "eve", "nite" }

-- Compile one decoded animation resource into a clip record.
--   opts.name            the Nitro dictionary entry name
--   opts.id              unique clip id (e.g. "a106-12")
--   opts.source          provenance block (archive, memberId, sha1)
local function compileOne(decoded, sectionReader, sectionLimit, opts)
  assert(
    #decoded.animations == 1,
    "animation resource must hold exactly one animation (corpus invariant), got " .. #decoded.animations
  )
  local anim = decoded.animations[1]
  opts.semanticNames = {}
  local role = MapPropAnimCompiler.roleFor(opts.name)
  if role then
    opts.semanticNames[1] = role
  end
  local clip
  if decoded.format == "NSBCA" then
    clip = NsbcaClipCompiler.compile(anim.resource, sectionReader, sectionLimit, opts)
  elseif decoded.format == "NSBTA" then
    clip = NsbtaClipCompiler.compile(anim.resource, sectionReader, sectionLimit, opts)
  elseif decoded.format == "NSBTP" then
    clip = NsbtpClipCompiler.compile(anim.resource, opts)
  elseif decoded.format == "NSBMA" then
    clip = NsbmaClipCompiler.compile(anim.resource, sectionReader, sectionLimit, opts)
  else
    Errors.raise(
      "MAP_PROP_ANIM_UNSUPPORTED_FORMAT",
      "animation resource "
        .. tostring(opts.source and opts.source.memberId)
        .. " has unsupported format "
        .. tostring(decoded.format),
      opts.source or {}
    )
  end
  return clip
end

-- Stamp the playback policy the runtime consumes: time-band metadata for a
-- banded record (each clip takes the band of its slot) and the ambient-loop
-- role for every clip of an ordinary-policy record. Compiled policy, so the
-- runtime never counts clips or guesses from names.
local function annotatePolicy(clips, record)
  if record.banded then
    for slot, clip in ipairs(clips) do
      clip.timeBand = BAND_BY_SLOT[slot]
    end
  end
  -- The ordinary registrar plays every id slot of an ordinary-policy record
  -- (ov01_021E8F3C), so the ambient role covers the whole record -- not a
  -- single-clip guess. Every other policy (door/interaction bit 0, load-only
  -- bit 1, the time-band special case) and a nonzero area gate keep the
  -- record off the ordinary registrar; those clips stay unmarked.
  local ordinaryPolicy = record.registration == 1
    and record.policy == 0
    and record.control == 0
    and record.areaGate == 0
  if ordinaryPolicy then
    for _, clip in ipairs(clips) do
      clip.ambientLoop = true
    end
  end
end

-- Resolve and compile the animation records of one model member.
--   opts.archiveAlias   "interior_build_anim_list" | "exterior_build_anim_list"
--   opts.memberId       the model's member id (the anim-list record index)
--   opts.resourceCache  optional plain memo table shared across a build run
--                       (resource member, sha1) -> compiled clip: each
--                       resource is decoded and compiled once, and every
--                       model that references it builds a per-model shallow
--                       copy (modelClip) so the memo's pristine record is
--                       never mutated by per-model playback policy. Both
--                       lists reference the shared build_anim archive, so
--                       the key carries no list identity.
--   listBytes           the model's anim-list record bytes
--   resNarc             the shared animation archive (a/1/0/6)
-- Returns { clips = {...} }. A referenced resource that cannot decode or
-- compile raises MAP_PROP_ANIM_UNRESOLVED; an animation format with no clip
-- compiler raises MAP_PROP_ANIM_UNSUPPORTED_FORMAT (no silent fallback).
function MapPropAnimCompiler.compile(listBytes, resNarc, opts)
  assert(
    type(listBytes) == "string" and #listBytes == 0x18,
    "MapPropAnimCompiler requires a 0x18-byte anim-list record"
  )
  assert(resNarc ~= nil and resNarc.readMember ~= nil, "MapPropAnimCompiler requires the shared animation archive")
  opts = opts or {}
  local BuildModelAnimList = require("romdump.src.digest.BuildModelAnimList")
  local record = BuildModelAnimList.decode(listBytes)

  local clips = {}
  local function compileResource(resourceId, bytes, sha1)
    local decoded, err = NitroAnimation.decode(bytes, { alias = ANIM_ARCHIVE, memberId = resourceId })
    if not decoded then
      Errors.raise(
        "MAP_PROP_ANIM_UNRESOLVED",
        "animation resource "
          .. tostring(resourceId)
          .. " referenced by model member "
          .. tostring(opts.memberId)
          .. " failed to decode: "
          .. tostring(err),
        { resourceId = resourceId, memberId = opts.memberId, archiveAlias = opts.archiveAlias or "-" }
      )
    end
    assert(decoded, "the raise above must not fall through")
    local source = {
      type = "nitro",
      format = decoded.format,
      archive = ANIM_ARCHIVE,
      memberId = resourceId,
      sha1 = sha1 or Hashing.sha1hex(bytes),
    }
    local ok, clip = pcall(compileOne, decoded, BinaryReader.new(decoded.bytes, "sec"), #decoded.bytes, {
      name = assert(decoded.animations[1]).name,
      id = string.format("%s-%d", ANIM_ARCHIVE, resourceId),
      source = source,
    })
    if not ok then
      -- A structured error from the clip compilers (e.g. an unsupported
      -- format) keeps its own code; any other failure is converted to the
      -- resource-resolution diagnostic.
      if Errors.is(clip) then
        error(clip)
      end
      Errors.raise(
        "MAP_PROP_ANIM_UNRESOLVED",
        "animation resource "
          .. tostring(resourceId)
          .. " referenced by model member "
          .. tostring(opts.memberId)
          .. " failed to compile: "
          .. tostring(clip),
        { resourceId = resourceId, memberId = opts.memberId, archiveAlias = opts.archiveAlias or "-" }
      )
    end
    return clip
  end

  -- A per-model shallow copy of the shared resource clip: the playback
  -- policy annotation (timeBand/ambientLoop) is per model and must never
  -- mutate the record other models share through the resource cache.
  local function modelClip(resourceId, bytes, sha1)
    local clip
    if opts.resourceCache then
      local cacheKey = string.format("%s:%d:%s", ANIM_ARCHIVE, resourceId, sha1 or Hashing.sha1hex(bytes))
      clip = opts.resourceCache[cacheKey]
      if not clip then
        clip = compileResource(resourceId, bytes, sha1)
        opts.resourceCache[cacheKey] = clip
      end
      local copy = {}
      for k, v in pairs(clip) do
        copy[k] = v
      end
      return copy
    end
    return compileResource(resourceId, bytes)
  end

  for _, resourceId in ipairs(record.ids) do
    clips[#clips + 1] = modelClip(resourceId, resNarc:readMember(resourceId))
  end
  annotatePolicy(clips, record)
  return { clips = clips }
end

return MapPropAnimCompiler
