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

Structures are grouped by their role. Source formats and references all live
under `romdump` — nothing outside it may interpret a structure whose meaning
comes from the NDS ROM, HGSS, or a decomp reference.

## Source formats and references

| Structure | Module | Source |
| --- | --- | --- |
| NDS cartridge header (title, game code, ARM9/ARM7, FNT/FAT/overlay pointers) | `romdump/src/source/NdsRom.lua` | GBATEK, "DS Cartridge Header" |
| FAT (zero-based `fileId`, exclusive end offsets) | `romdump/src/source/NdsRom.lua` | GBATEK, "NitroROM File System" |
| FNT (recursive directory/file name table, `firstFileId`) | `romdump/src/source/NitroFs.lua` | GBATEK, "NitroROM File System" |
| ARM9/ARM7 overlay tables (32-byte entries) | `romdump/src/source/OverlayTable.lua` | GBATEK, "DS Cartridge Header" (overlay table) |
| NARC container (`NARC`/`BTAF`/`BTNF`/`GMIF` blocks, GMIF-relative member offsets) | `romdump/src/source/Narc.lua` | `pret/pokeheartgold`: `tools/o2narc/Narc.h`, `src/filesystem.c` |
| NARC catalog (`NarcId` enum ↔ NitroFS path) | `romdump/src/reference/hgss/narcs.lua` | `pret/pokeheartgold`: `include/filesystem_files_def.h` |
| Map-header catalog | `romdump/src/reference/hgss/maps.lua` | `pret/pokeheartgold`: `include/constants/maps.h`, `include/encounter_tables_narc.h`, `src/data/map_headers.h` |
| Map renderability, representative cells, and land members | generated `world.lua` analysis | `WorldManifest.write` during `romdump --build-cache` over the user's canonical dump |
| Curated aliases + required set | `romdump/src/config/HgssArchives.lua` | gen4recomp runtime interface over the frozen NARC reference |
| Map-matrix member layout (width/height, optional headers & altitudes, model IDs) | `romdump/src/digest/MapMatrix.lua` | `pret/pokeheartgold`: `src/map_matrix.c`, `include/map_matrix.h` |
| Area-data member layout (texture packs, dynamic texture, area/light type) | `romdump/src/digest/AreaData.lua` | `pret/pokeheartgold`: `src/fielddata.c`, `include/fielddata.h` |
| Land-data container (BGS, permissions, buildings, model, BDHC) | `romdump/src/digest/LandData.lua` | `pret/pokeheartgold`: `src/land_data.c`, `include/land_data.h` |
| HGSS permission section (0x80 hard-block encoding) → normalized collision grid | `romdump/src/digest/HgssPermissionGrid.lua` | `pret/pokeheartgold` field movement code (bit 15 of the u16 pair blocks, low 7 bits are the terrain response); canonical map cells validate every byte |
| HGSS 17-record field-camera table and initialization | `romdump/src/digest/HgssCameraTable.lua`, `romdump/src/digest/FieldCameraDiscovery.lua` | `pret/pokeheartgold`: `src/camera.c` and ARM9 overlay 1 assembly at the pinned revision; canonical overlay bytes validate discovery |
| Field-actor graphics table, visual descriptors, model/timeline key tables, and animation ranges | `romdump/src/digest/FieldActorGraphics.lua`, `romdump/src/config/FieldActors.lua` | `pret/pokeheartgold`: `asm/overlay_01_sprite_data.s`, `asm/overlay_01_021F8D80.s`, `asm/overlay_01_021F944C.s`, `asm/unk_02023694.s`, `include/map_object.h`; canonical overlay bytes validate every record, key, and range |
| Field-actor timeline members (frame thresholds → texture/palette slots) | `romdump/src/digest/FieldActorTimeline.lua` | `pret/pokeheartgold`: `scripts/dump_mmodel_unk.py`, `asm/unk_02026DE0.s` |
| Zone background, object, warp, and coordinate events | `romdump/src/digest/ZoneEvents.lua` | `pret/pokeheartgold`: field event structures and consumers; canonical target-map bytes validate counts and destinations |
| HGSS BDHC points, slopes, heights, plates, strips, and access lists | `romdump/src/digest/HgssBdhc.lua` | `Pokemon-DS-Map-Studio`: `BdhcLoaderHGSS.java`, `BdhcWriterHGSS.java` at `ac30b653e5b090ce116278ed6ba9758fff956673`; target facts checked against the canonical dump |
| `NNSG3dResMatData` fixed prefix (item tag, size, color words, polygon attributes, texture params, flags, original size) | `romdump/src/digest/nitro/Nsbmd.lua` | NitroSDK `res_struct.h` (`NNSG3dResMatData`), GBATEK "GX 3D" for `POLYGON_ATTR`, `DIF_AMB`, `SPE_EMI` packing |
| DS geometry-engine display list | `romdump/src/digest/nitro/GxDisplayList.lua` | GBATEK "DS Video Geometry Commands" |
| HGSS field-light profile text format and `lightTypeRaw` → profile mapping | `romdump/src/digest/HgssFieldLightProfile.lua`, `romdump/src/digest/HgssFieldLighting.lua` | `pret/pokeheartgold`: `src/field_light.c`, `include/field_light.h`; profile tables under `data/area*light.txt` |
| Accepted ROM SHA-1s and game codes | `romdump/src/source/GameVersion.lua` | `pret/pokeheartgold`: `README.md` (canonical US hashes) |
| Message-bank MAT container and decryption (count/key header, encrypted offset/length table, two-stage u16 stream cipher) | `romdump/src/digest/FieldMessageBank.lua` | `pret/pokeheartgold`: `include/msgdata.h` (`MAT`, `MAT_ENTRY`), `src/msgdata.c` (`Decrypt1`, `Decrypt2`); canonical bank members validate counts and decryption |
| Message code units → lossless token stream (glyphs, LF/prompt/page breaks, extended controls) | `romdump/src/digest/FieldMessageTokenizer.lua`, `romdump/src/reference/hgss/charmap.lua` | `pret/pokeheartgold`: `charmap.txt`, `include/constants/charcode.h`, `src/string_control_code.c`; canonical banks 542/543 validate the control signature set |
| Field font member (16-byte header, 2bpp 8x8 sub-tiles, width table) and RLCN/TTLP palette member | `romdump/src/digest/FieldFontDecoder.lua` | `pret/pokeheartgold`: `src/font_data.c` (`FontData_Init`, `TryLoadGlyph`), `src/text.c` (`GenerateFontHalfRowLookupTable`), `src/font.c` (`LoadFontPal0`); GBATEK Nitro Color Palette/TTLP layout; canonical font member 0 and palette member 7 validate geometry |
| Map-header message/script bank association | `romdump/src/reference/hgss/maps.lua` (`messageMemberId`/`scriptsMemberId`), emitted by `romdump/src/digest/FieldMapDataCompiler.lua` | `pret/pokeheartgold`: `src/data/map_headers.h` (`.msgBank`, `.scriptsBank`) |
| Field-script command catalog (opcode → name, operand widths, execution classification, arg-dependent width variants) | `romdump/src/reference/hgss/script_commands.lua`, `romdump/src/digest/script/CommandCatalog.lua` | `pret/pokeheartgold`: `src/data/fieldmap/script_cmd_table.h`, `asm/macros/script.inc`; canonical scr_seq members validate widths |
| Field-script binary member layout (relative entry table, `SCRDEF_END` sentinel, interleaved movement blocks, signed relative targets, message-index operands) | `romdump/src/digest/script/ScriptBinaryDecoder.lua` | `pret/pokeheartgold`: `asm/macros/script.inc` (`ScrDef`/`ScrDefEnd`), `asm/macros/movement.inc`; canonical scr_seq members validate the layout |
| Movement command catalog (code → macro name, u16 arg count) | `romdump/src/reference/hgss/movement_commands.lua` | `pret/pokeheartgold`: `include/constants/movements.h`, `asm/macros/movement.inc` |
| Standard-script catalog (CallStd id → public name, script-bank mapping) | `romdump/src/reference/hgss/std_script_catalog.lua`, `romdump/src/digest/script/SourceCatalog.lua` | `pret/pokeheartgold`: `include/constants/std_script.h`, `src/script_manager.c` (`sScriptBankMapping`) |
| Script-member message banks (NPCMsg indices resolve through the owning map's bank) | `romdump/src/reference/hgss/script_members.lua` | `pret/pokeheartgold`: `src/data/map_headers.h`, `src/script_manager.c`; cross-checked against the per-member `.s` includes |
| Sound-sequence, flag, and variable catalogs (numeric operands → decomp names) | `romdump/src/reference/hgss/sndseq.lua`, `flags.lua`, `vars.lua` | `pret/pokeheartgold`: `include/constants/sndseq.h`, `flags.h`, `vars.h` |

## Derived asset formats

Project-owned formats generated by `romdump` producers and consumed through
`libs/assets` contracts. A custom tool can produce or consume these without
understanding the source ROM.

| Structure | Module | Source |
| --- | --- | --- |
| Collision asset (`G4CL`: width/height, per-cell behavior/terrain-response/blocked) | `libs/assets/src/CollisionGridAsset.lua` | g4recomp-defined replacement for the HGSS permission section |
| Map cache (scene, terrain surfaces, collision, neighbors) and readiness | `libs/assets/src/MapAssetCache.lua` | g4recomp-defined; scene/terrain schemas in `DerivedAssetContract` |
| Camera profile cache (paths, marker, schema) | `libs/assets/src/FieldCameraCache.lua` | g4recomp-defined over `HgssCameraTable`/`FieldCameraDiscovery` records |
| Field-actor cache and index (including the runtime avatar/variable-sprite config) | `libs/assets/src/FieldActorCache.lua` | g4recomp-defined over `FieldActorGraphics` records |
| Field map data cache and field resource | `libs/assets/src/FieldMapDataCache.lua` | g4recomp-defined over `ZoneEvents` and map-header events |
| Message bank cache and lossless text form (GMM-style markers) | `libs/assets/src/FieldMessageCache.lua`, `FieldMessageText.lua` | g4recomp-defined over MAT members |
| Font cache (atlas + metrics) | `libs/assets/src/FieldFontCache.lua` | g4recomp-defined over the HGSS font member |
| Script cache (compiled resources + index + provenance) | `libs/assets/src/ScriptCache.lua` | g4recomp-defined; the public `gen4.script` DSL owns the script API version |
| Mesh and vertex formats (`G4M2`, vertex layouts) | `libs/assets/src/MeshWriter.lua`, `VertexFormat.lua` | g4recomp-defined |
| Field light profile selection (normalized records + time-of-day select) | `libs/assets/src/FieldLightProfile.lua` | g4recomp-defined over `HgssFieldLightProfile` output |
| Script symbol and menu-protocol contracts | `libs/assets/src/FieldScriptSymbols.lua`, `MenuProtocol.lua` | g4recomp-defined; single stores for flag/var names and menu constants |

## Runtime interpretations

`libs/engine` and `game` consume only derived assets and their own game
concepts; a row here never names a source decoder.

| Structure | Module | Source |
| --- | --- | --- |
| Field camera runtime math (raw angle indices → DS camera motion) | `libs/engine/src/FieldCamera.lua` | generated camera profiles only |
| Collision, terrain surface, and surface resolution | `libs/engine/src/CollisionGrid.lua`, `TerrainSurface.lua`, `SurfaceResolver.lua` | generated `G4CL` and terrain artifacts only |
| Scene mesh decode and GPU scene assembly | `libs/engine/src/SceneMesh.lua`, `MapSceneLoader.lua` | generated map artifacts only |
| Lighting behavior (time-of-day selection and binding) | `libs/engine/src/DsLighting.lua`, `RenderQueue.lua` | generated light profiles only |
