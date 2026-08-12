-- Private regression inventory: every animated ROM asset is inventoried and
-- none may compile with a silent fallback. The two
-- anim-list archives (a/1/0/7 exterior, a/1/0/8 interior) are the complete
-- inventory of animated model members -- each record's resource ids index
-- the shared animation archive (a/1/0/6) -- so walking every record and
-- compiling every referenced resource covers every animated asset the field
-- builds. A resource that cannot decode or compile now raises an explicit
-- MAP_PROP_ANIM_UNRESOLVED / MAP_PROP_ANIM_UNSUPPORTED_FORMAT diagnostic
-- (nothing returns an unresolved list and compiles the model static), so a
-- raise here IS the "either compiles or explicit diagnostic" outcome; the
-- corpus must raise nothing. Counts below are pinned against the heartgold
-- dump, identified by its checksum (asserted by the census test): any
-- drift in the archive layout or the resource set fails the test and
-- requires an audit before re-pinning.

local Assert = require("tests.support.Assert")
local MapPropAnimCompiler = require("romdump.src.digest.MapPropAnimCompiler")
local BuildModelAnimList = require("romdump.src.digest.BuildModelAnimList")

local T = {}

-- Walk every anim-list record of an archive, compiling every referenced
-- resource. Raises (fails the test) on any broken resource; returns the
-- inventory: { members, records, clips, formats }.
local function inventoryArchive(romFs, alias)
  local animResNarc = assert(romFs:openNarc("build_anim"))
  local narc = assert(romFs:openNarc(alias))
  local inventory = { members = narc:memberCount(), records = 0, clips = 0, formats = {} }
  for memberId = 0, inventory.members - 1 do
    local listBytes = assert(narc:readMember(memberId), "read anim-list record " .. memberId)
    local record = BuildModelAnimList.decode(listBytes)
    Assert.isTrue(#record.ids <= 4, "an anim-list record holds at most four resource ids")
    local result = MapPropAnimCompiler.compile(listBytes, animResNarc, {
      archiveAlias = alias,
      memberId = memberId,
    })
    if #result.clips > 0 then
      inventory.records = inventory.records + 1
    end
    for _, clip in ipairs(result.clips) do
      inventory.clips = inventory.clips + 1
      inventory.formats[clip.source.format] = (inventory.formats[clip.source.format] or 0) + 1
      -- Every clip carries the full provenance and a sane frame count; the
      -- id embeds the shared build_anim resource it was compiled from.
      Assert.equal(clip.source.type, "nitro")
      Assert.equal(clip.source.archive, "build_anim")
      Assert.isTrue(clip.source.memberId >= 0)
      Assert.isTrue(type(clip.source.sha1) == "string" and #clip.source.sha1 == 40, "clip sha1 provenance")
      Assert.equal(clip.id, "build_anim-" .. tostring(clip.source.memberId))
      Assert.isTrue(clip.frameCount >= 2, "sane clip frame count")
      Assert.isTrue(#clip.name > 0, "clip carries its Nitro dictionary name")
    end
  end
  return inventory
end

-- The complete animated-asset inventory of the real ROM: no silent fallback
-- anywhere (any broken resource would raise MAP_PROP_ANIM_UNRESOLVED and
-- fail this test), and the counts are pinned.
function T.every_animated_asset_compiles_with_an_explicit_outcome(romFs)
  -- Durable provenance: the pinned census belongs to exactly one ROM
  -- revision, identified by its dump checksum (the game version alone
  -- would not distinguish revisions). Any other dump fails here, and the
  -- counts below must be re-audited before re-pinning.
  Assert.equal(
    romFs:metadata().sha1,
    "4fcded0e2713dc03929845de631d0932ea2b5a37",
    "the census pins the heartgold dump (IPKE) checksum"
  )
  local animResNarc = assert(romFs:openNarc("build_anim"))
  Assert.equal(animResNarc:memberCount(), 273, "shared animation archive member count")

  local exterior = inventoryArchive(romFs, "exterior_build_anim_list")
  local interior = inventoryArchive(romFs, "interior_build_anim_list")

  Assert.equal(exterior.members, 340, "exterior anim-list member count")
  Assert.equal(interior.members, 222, "interior anim-list member count")
  Assert.equal(exterior.records, 146, "exterior records with animations")
  Assert.equal(interior.records, 94, "interior records with animations")
  Assert.equal(exterior.clips, 319, "exterior clip embeddings")
  Assert.equal(interior.clips, 140, "interior clip embeddings")

  -- Format histogram across every embedding (the census's format spread:
  -- no NSBVA in the field corpus -- its decoder stays test-proven only).
  local formats = {}
  for k, v in pairs(exterior.formats) do
    formats[k] = (formats[k] or 0) + v
  end
  for k, v in pairs(interior.formats) do
    formats[k] = (formats[k] or 0) + v
  end
  Assert.equal(formats.NSBCA, 198)
  Assert.equal(formats.NSBTA, 129)
  Assert.equal(formats.NSBTP, 122)
  Assert.equal(formats.NSBMA, 10)
  Assert.equal(formats.NSBVA, nil, "no NSBVA resource is referenced")
end

-- The shared door pair (resources 1/2 = door_op/door_cl) is the corpus's
-- most-referenced resource set; every record that references it must get the
-- door semantics: an 8-frame NSBCA clip with the door.open/door.close role.
function T.door_resources_always_compile_with_door_semantics(romFs)
  local animResNarc = assert(romFs:openNarc("build_anim"))
  local seen = { ["door.open"] = 0, ["door.close"] = 0 }
  for _, alias in ipairs({ "exterior_build_anim_list", "interior_build_anim_list" }) do
    local narc = assert(romFs:openNarc(alias))
    for memberId = 0, narc:memberCount() - 1 do
      local listBytes = assert(narc:readMember(memberId))
      for _, clip in
        ipairs(MapPropAnimCompiler.compile(listBytes, animResNarc, {
          archiveAlias = alias,
          memberId = memberId,
        }).clips)
      do
        if clip.source.memberId == 1 or clip.source.memberId == 2 then
          Assert.equal(clip.source.format, "NSBCA")
          Assert.equal(clip.frameCount, 8, "door_op/door_cl are 8-frame NSBCA clips")
          Assert.isTrue(#clip.semanticNames == 1, "door resources carry the door role")
          seen[clip.semanticNames[1]] = seen[clip.semanticNames[1]] + 1
        end
      end
    end
  end
  Assert.isTrue(seen["door.open"] > 0, "door.open is referenced")
  Assert.isTrue(seen["door.close"] > 0, "door.close is referenced")
end

return require("tests.rom.support.RomSuite").fromFacts(T)
