-- MapPropAnimCompiler: resolves a map-prop model's animation records (a
-- member of the exterior/interior build-anim-list archive, HGSS a/1/0/7 and
-- a/1/0/8) into compiled animation clips for the model descriptor. Each
-- record's resource ids index the shared animation archive (a/1/0/6), whose
-- members are any of the five Nitro animation formats; the matching decoder
-- is dispatched by format and compiled by the matching clip compiler, so the
-- runtime never touches Nitro animation bytes.
--
-- Semantic roles: clip names are the source-format identifiers; gameplay
-- must not depend on them (spec section 27). The door open/close pairs the
-- field corpus uses are mapped onto the door.open/door.close roles by name
-- pattern:
--
--   *door_op  -> door.open    *door_cl  -> door.close
--   *door_mop -> door.open    *door_mcl -> door.close
--
-- Every other clip keeps its name as the addressable id (prop.play("wind")).
-- The mapping is a compile-time policy decision, not a runtime assumption.
-- Pure domain module.

local BinaryReader = require("libs.rom.src.BinaryReader")
local Errors = require("libs.rom.src.Errors")
local Hashing = require("romdump.src.digest.Hashing")
local NitroAnimation = require("romdump.src.digest.nitro.NitroAnimation")
local NsbcaClipCompiler = require("romdump.src.digest.NsbcaClipCompiler")
local NsbtaClipCompiler = require("romdump.src.digest.NsbtaClipCompiler")
local NsbtpClipCompiler = require("romdump.src.digest.NsbtpClipCompiler")
local NsbmaClipCompiler = require("romdump.src.digest.NsbmaClipCompiler")

local MapPropAnimCompiler = {}

-- Version of the animation decode + clip-compile semantics. Cache keys of
-- compiled assets must account for it (spec section 41): a decoder or
-- sampler change without it would leave stale compiled clips in the derived
-- cache. Bump whenever the decoders or the clip compilers change behavior.
MapPropAnimCompiler.VERSION = "map-prop-anim-clip-v1"

-- clip name -> semantic role. Patterns match the tail of the Nitro dict
-- name; the whole name matches when the pattern is exact.
local ROLE_PATTERNS = {
  door_op = "door.open",
  door_cl = "door.close",
  door_mop = "door.open",
  door_mcl = "door.close",
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

-- Compile one decoded animation resource into a clip record.
--   opts.name            the Nitro dictionary entry name
--   opts.id              unique clip id (e.g. "a106-12")
--   opts.source          provenance block (archive, memberId, sha1)
local function compileOne(decoded, sectionReader, sectionLimit, opts)
  local anim = assert(decoded.animations[1], "animation resource with no entries")
  opts.semanticNames = {}
  local role = MapPropAnimCompiler.roleFor(opts.name)
  if role then
    opts.semanticNames[1] = role
  end
  if decoded.format == "NSBCA" then
    return NsbcaClipCompiler.compile(anim.resource, sectionReader, sectionLimit, opts)
  elseif decoded.format == "NSBTA" then
    return NsbtaClipCompiler.compile(anim.resource, sectionReader, sectionLimit, opts)
  elseif decoded.format == "NSBTP" then
    return NsbtpClipCompiler.compile(anim.resource, opts)
  elseif decoded.format == "NSBMA" then
    return NsbmaClipCompiler.compile(anim.resource, sectionReader, sectionLimit, opts)
  end
  Errors.raise(
    "MAP_PROP_ANIM_UNSUPPORTED_FORMAT",
    "animation resource "
      .. tostring(opts.source and opts.source.memberId)
      .. " has unsupported format "
      .. tostring(decoded.format),
    opts.source or {}
  )
end

-- Resolve and compile the animation records of one model member.
--   opts.archiveAlias   "interior_build_anim_list" | "exterior_build_anim_list"
--   opts.memberId       the model's member id (the anim-list record index)
--   opts.resourceCache  optional AnimationResourceCache shared across a build
--                       run: each (archive, resource member, sha1) tuple is
--                       decoded and compiled once, and every model that
--                       references the resource embeds the same immutable
--                       clip record (identity-shared; never mutated).
--   listBytes           the model's anim-list record bytes
--   resNarc             the shared animation archive (a/1/0/6)
-- Returns { clips = {...}, unresolved = { { resourceId, error } } }.
function MapPropAnimCompiler.compile(listBytes, resNarc, opts)
  assert(
    type(listBytes) == "string" and #listBytes == 0x18,
    "MapPropAnimCompiler requires a 0x18-byte anim-list record"
  )
  assert(resNarc ~= nil and resNarc.readMember ~= nil, "MapPropAnimCompiler requires the shared animation archive")
  opts = opts or {}
  local BuildModelAnimList = require("romdump.src.digest.BuildModelAnimList")
  local record = BuildModelAnimList.decode(listBytes)

  local clips, unresolved = {}, {}
  local function compileResource(resourceId, bytes, sha1)
    local decoded, err = NitroAnimation.decode(bytes, { alias = "build_anim", memberId = resourceId })
    if not decoded then
      return nil, err
    end
    local source = {
      type = "nitro",
      format = decoded.format,
      archive = "build_anim",
      memberId = resourceId,
      sha1 = sha1 or Hashing.sha1hex(bytes),
    }
    local name = assert(decoded.animations[1]).name
    return compileOne(decoded, BinaryReader.new(decoded.bytes, "sec"), #decoded.bytes, {
      name = name,
      id = opts.archiveAlias and string.format("%s-%d", opts.archiveAlias, resourceId) or tostring(resourceId),
      source = source,
    })
  end

  for _, resourceId in ipairs(record.ids) do
    local clip, err
    if opts.resourceCache then
      local bytes = resNarc:readMember(resourceId)
      local sha1 = Hashing.sha1hex(bytes)
      local cacheKey = string.format("%s:%d:%s", opts.archiveAlias or "-", resourceId, sha1)
      clip = opts.resourceCache:get(cacheKey)
      if not clip then
        clip, err = compileResource(resourceId, bytes, sha1)
        if clip then
          opts.resourceCache:set(cacheKey, clip)
        end
      end
    else
      clip, err = compileResource(resourceId, resNarc:readMember(resourceId))
    end
    if not clip then
      unresolved[#unresolved + 1] = { resourceId = resourceId, error = err }
    else
      clips[#clips + 1] = clip
    end
  end
  return { clips = clips, unresolved = unresolved }
end

return MapPropAnimCompiler
