-- Locator metadata for the HGSS field-actor graphics tables. The overlay 1
-- tables are addressed by their original
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
      "asm/overlay_01_021FD1B8.s",
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

  -- Descriptor 63 is a sentinel for the separate static map-object renderer.
  -- ov01_02208E30 maps those sprite IDs to self-contained NSBMD members.
  staticModels = {
    descriptor = 63,
    table = { address = 0x02208E30, count = 12 },
    archive = { alias = "field_static_models", path = "a/1/0/3" },
  },

  -- global_fieldmap.h direction order. The index is the animation-range index
  -- inside a descriptor's range table; east is never a mirror of west.
  directionOrder = { "north", "south", "west", "east" },

  -- FieldSystem_ResolveObjectSpriteID redirects this inclusive range through
  -- field variables before the graphics lookup (`src/map_object.c`), so these
  -- IDs are absent from the table by design. spriteId `s` reads variable
  -- `variableVarBase + (s - first)` once, at object creation
  -- (`src/script_manager.c`). Every variable defaults to 0, the hero graphic.
  variableSpriteRange = { first = 101, last = 117 },
  -- VAR_OBJ_GFX_BASE (`include/constants/vars.h`). The decomp flags spriteId
  -- 117 as an off-by-one reading the variable past the sixteen VAR_OBJ_* slots;
  -- the var-base formula above reproduces that original behavior.
  variableVarBase = 0x4020,

  -- The player graphics available to a field session. Gender uses the same
  -- validated player-profile values as PlayerData (0 = male, 1 = female).
  avatars = {
    { id = "hero", spriteId = 0, gender = 0 },
    { id = "heroine", spriteId = 97, gender = 1 },
  },

  -- Pinned source for the HEAL/BANZAI give/receive visuals: src/player_avatar.c
  -- PlayerAvatar_GetSpriteByStateAndGender(PLAYER_STATE_HEAL, gender) selects
  -- SPRITE_BANZAIHERO (200) and SPRITE_BANZAIHEROINE (201)
  -- (pret/pokeheartgold@b23531f6c82fc6a785058825a447d8439b38e47f, asm/overlay_01_sprite_data.s,
  -- asm/overlay_01_021F72DC.s, src/player_avatar.c). Added explicitly because the
  -- current avatar set does not cover these state-driven sprites, yet their
  -- descriptor ranges are required for the semantic give/receive clips.
  gestureSpriteIds = { 200, 201 },

  -- Common placement recovered from the field-actor loader and billboard models:
  -- a bottom-center local origin, the Nitro SBC full camera-facing billboard
  -- command, and the loader's six-model-unit Y offset. Frame dimensions come
  -- from each resource; the ordinary actor model is 32x32 and rocks are 16x16.
  placement = {
    pivot = { x = 0.5, y = 1.0 },
    modelOffset = { x = 0, y = 0, z = 6 },
    billboardMode = "cameraFacingFull",
    mirrorEastWest = false,
  },
}
