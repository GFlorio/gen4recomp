-- Locator metadata for the HGSS field-actor graphics tables and the actor
-- selected-set policy. The overlay 1 tables are addressed by their original
-- runtime (RAM) addresses; the importer converts them to overlay offsets using
-- the load address the ROM's own overlay table reports, so no raw .nds file
-- offset is ever hardcoded. Addresses are read from `asm/overlay_01_sprite_data.s`,
-- `asm/overlay_01_021F8D80.s`, and `asm/overlay_01_021F944C.s` in the pinned
-- pret/pokeheartgold source and validated byte-for-byte against every supported
-- ROM at import time. Pure data; no love dependency.

return {
  schema = 1,

  provenance = {
    repo = "pret/pokeheartgold",
    commit = "b23531f6c82fc6a785058825a447d8439b38e47f",
    sources = {
      "asm/overlay_01_sprite_data.s",
      "asm/overlay_01_021F8D80.s",
      "asm/overlay_01_021F944C.s",
      "asm/unk_02023694.s",
      "include/map_object.h",
      "src/map_object.c",
    },
  },

  -- Overlay 1 (ARM9) holds every field-actor table. Runtime addresses only.
  overlay = { cpu = "arm9", overlayId = 1 },

  tables = {
    -- ObjectEvent_GetGraphicsInfo scans this in six-byte steps to the 0xFFFF
    -- terminator. The expectations are invariants, not a substitute for parsing.
    graphics = {
      address = 0x022074A8,
      expectedRecordCount = 901,
      expectedTerminatorOffset = 0x151E,
    },
    -- ov01_02207318: 24 eight-byte visual descriptors selected by packed bits 10-15.
    descriptors = { address = 0x02207318, count = 24 },
    -- Flat u16 (key, memberId) pair arrays, terminated by key 255.
    modelKeys = { address = 0x02207294 },
    timelineKeys = { address = 0x022072CC },
  },

  -- The NitroFS path of the field-actor archive (`data/mmodel/mmodel`).
  archive = { alias = "field_actor_models", path = "a/0/8/1" },

  -- global_fieldmap.h direction order. The index is the animation-range index
  -- inside a descriptor's range table; east is never a mirror of west.
  directionOrder = { "north", "south", "west", "east" },

  -- FieldSystem_ResolveObjectSpriteID redirects this inclusive range through
  -- field variables before the graphics lookup, so these IDs are absent from the
  -- table by design. Every value they can take is a player graphic.
  variableSpriteRange = { first = 101, last = 117 },

  -- Movement codes whose runtime behavior is verified to be "stand still".
  -- Every other code is preserved on the actor and reported once through the
  -- developer trace; autonomous motion is out of scope for this milestone, so
  -- widening this set requires verifying the code against original behavior.
  staticMovementCodes = { 0 },

  -- Selected-set policy (specification 17.1): the player graphics plus every
  -- object-event sprite used by these maps. Production code never branches on a
  -- map ID; this manifest is the single configuration point that widens the set.
  selectedSet = {
    alwaysSprites = { 0, 97 }, -- hero, heroine
    maps = { "MAP_NEW_BARK", "MAP_NEW_BARK_ELMS_LAB_1F" },
  },

  -- Source-space placement recovered from shared model member 266 (mmdl_m32x32):
  -- a single 32x32 quad with a bottom-center local origin, drawn with the Nitro
  -- SBC full camera-facing billboard command, offset six model units up on Y.
  placement = {
    sourceSize = { width = 32, height = 32 },
    pivot = { x = 0.5, y = 1.0 },
    modelYOffset = 6,
    billboardMode = "cameraFacingFull",
    mirrorEastWest = false,
  },
}
