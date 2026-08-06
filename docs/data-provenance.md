# Data provenance

Every binary structure g4recomp parses is derived from a public reference, not
guessed. This document maps each implemented structure to its authoritative
source so the parsing can be audited and refreshed. The repository itself
contains **no** copyrighted ROM payload — only the metadata needed to interpret
a ROM the user supplies.

## Reference sources

- **GBATEK** — the Nintendo DS hardware/BIOS reference. Sections "DS Cartridge
  Header" and "DS Cartridge NitroROM File System" define the header layout, FAT,
  FNT, and overlay tables.
- **`pret/pokeheartgold`** — the HGSS decompilation. Used only for *semantic*
  interpretation (NARC names, map headers, member layouts), never for physical
  file IDs.

When a decomp name conflicts with the bytes of a canonical, hash-verified ROM,
the ROM's FNT/FAT is authoritative for physical paths and file IDs; the decomp
is authoritative only for semantic naming and structure interpretation.

## Structure → source

| Structure | Module | Source |
| --- | --- | --- |
| NDS cartridge header (title, game code, ARM9/ARM7, FNT/FAT/overlay pointers) | `libs/rom/src/NdsRom.lua` | GBATEK, "DS Cartridge Header" |
| FAT (zero-based `fileId`, exclusive end offsets) | `libs/rom/src/NdsRom.lua` | GBATEK, "NitroROM File System" |
| FNT (recursive directory/file name table, `firstFileId`) | `libs/rom/src/NitroFs.lua` | GBATEK, "NitroROM File System" |
| ARM9/ARM7 overlay tables (32-byte entries) | `libs/rom/src/OverlayTable.lua` | GBATEK, "DS Cartridge Header" (overlay table) |
| NARC container (`NARC`/`BTAF`/`BTNF`/`GMIF` blocks, GMIF-relative member offsets) | `libs/rom/src/Narc.lua` | `pret/pokeheartgold`: `tools/o2narc/Narc.h`, `src/filesystem.c` |
| NARC catalog (`NarcId` enum ↔ NitroFS path) | `data/reference/hgss/narcs.lua` | `pret/pokeheartgold`: `include/filesystem_files_def.h` |
| Map-header catalog | `data/reference/hgss/maps.lua` | `pret/pokeheartgold`: `include/constants/maps.h`, `include/encounter_tables_narc.h`, `src/data/map_headers.h` |
| Map renderability, representative cells, and land members | generated `world.lua` analysis | `scripts/analyze-maps.sh` over the user's canonical dump |
| Curated aliases + required set | `data/manifests/hgss.lua` | gen4recomp runtime interface over the frozen NARC reference |
| Map-matrix member layout (width/height, optional headers & altitudes, model IDs) | `libs/assets/src/MapMatrix.lua` | `pret/pokeheartgold`: `src/map_matrix.c`, `include/map_matrix.h` |
| Area-data member layout (texture packs, dynamic texture, area/light type) | `libs/assets/src/AreaData.lua` | `pret/pokeheartgold`: `src/fielddata.c`, `include/fielddata.h` |
| Land-data container (BGS, permissions, buildings, model, BDHC) | `libs/assets/src/LandData.lua` | `pret/pokeheartgold`: `src/land_data.c`, `include/land_data.h` |
| HGSS 17-record field-camera table and initialization | `libs/assets/src/HgssCameraTable.lua`, `libs/engine/src/FieldCamera.lua` | `pret/pokeheartgold`: `src/camera.c` and ARM9 overlay 1 assembly at the pinned revision; canonical overlay bytes validate discovery |
| Field-actor graphics table, visual descriptors, model/timeline key tables, and animation ranges | `romdump/src/digest/FieldActorGraphics.lua`, `data/manifests/field_actors.lua` | `pret/pokeheartgold`: `asm/overlay_01_sprite_data.s`, `asm/overlay_01_021F8D80.s`, `asm/overlay_01_021F944C.s`, `asm/unk_02023694.s`, `include/map_object.h`; canonical overlay bytes validate every record, key, and range |
| Field-actor timeline members (frame thresholds → texture/palette slots) | `romdump/src/digest/FieldActorTimeline.lua` | `pret/pokeheartgold`: `scripts/dump_mmodel_unk.py`, `asm/unk_02026DE0.s` |
| Zone background, object, warp, and coordinate events | `libs/assets/src/ZoneEvents.lua` | `pret/pokeheartgold`: field event structures and consumers; canonical target-map bytes validate counts and destinations |
| HGSS BDHC points, slopes, heights, plates, strips, and access lists | `libs/assets/src/HgssBdhc.lua` | `Pokemon-DS-Map-Studio`: `BdhcLoaderHGSS.java`, `BdhcWriterHGSS.java` at `ac30b653e5b090ce116278ed6ba9758fff956673`; target facts checked against the canonical dump |
| `NNSG3dResMatData` fixed prefix (item tag, size, color words, polygon attributes, texture params, flags, original size) | `libs/assets/src/nitro/Nsbmd.lua` | NitroSDK `res_struct.h` (`NNSG3dResMatData`), GBATEK "GX 3D" for `POLYGON_ATTR`, `DIF_AMB`, `SPE_EMI` packing |
| DS geometry-engine display list | `libs/assets/src/nitro/GxDisplayList.lua` | GBATEK "DS Video Geometry Commands" |
| HGSS field-light profile text format and `lightTypeRaw` → profile mapping | `libs/assets/src/FieldLightProfile.lua`, `libs/assets/src/HgssFieldLighting.lua` | `pret/pokeheartgold`: `src/field_light.c`, `include/field_light.h`; profile tables under `data/area*light.txt` |
| Accepted ROM SHA-1s and game codes | `libs/rom/src/GameVersion.lua` | `pret/pokeheartgold`: `README.md` (canonical US hashes) |
| Message-bank MAT container and decryption (count/key header, encrypted offset/length table, two-stage u16 stream cipher) | `romdump/src/digest/FieldMessageBank.lua` | `pret/pokeheartgold`: `include/msgdata.h` (`MAT`, `MAT_ENTRY`), `src/msgdata.c` (`Decrypt1`, `Decrypt2`); canonical bank members validate counts and decryption |
| Message code units → lossless token stream (glyphs, LF/prompt/page breaks, extended controls) | `romdump/src/digest/FieldMessageTokenizer.lua`, `data/reference/hgss/charmap.lua` | `pret/pokeheartgold`: `charmap.txt`, `include/constants/charcode.h`, `src/string_control_code.c`; canonical banks 542/543 validate the control signature set |
| Field font member (16-byte header, 2bpp 8x8 sub-tiles, width table) and RLCN/TTLP palette member | `romdump/src/digest/FieldFontDecoder.lua` | `pret/pokeheartgold`: `src/font_data.c` (`FontData_Init`, `TryLoadGlyph`), `src/text.c` (`GenerateFontHalfRowLookupTable`), `src/font.c` (`LoadFontPal0`); GBATEK Nitro Color Palette/TTLP layout; canonical font member 0 and palette member 7 validate geometry |
| Map-header message/script bank association | `data/reference/hgss/maps.lua` (`messageMemberId`/`scriptsMemberId`), emitted by `FieldMapDataCompiler` | `pret/pokeheartgold`: `src/data/map_headers.h` (`.msgBank`, `.scriptsBank`) |
