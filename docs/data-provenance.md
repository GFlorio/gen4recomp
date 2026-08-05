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
  interpretation (NARC names, member layouts), never for physical file IDs.
  The generated NARC catalog records the exact commit it was built from:
  - repo: `pret/pokeheartgold`
  - commit: `1a7f2c301c954df2d19d7f9211529f6decc8dede`

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
| NARC catalog (`NarcId` enum ↔ NitroFS path) | `data/manifests/narc_catalog.lua` | `pret/pokeheartgold`: `include/filesystem_files_def.h` |
| Curated aliases + required set | `data/manifests/hgss.lua` | `pret/pokeheartgold`: `include/filesystem_files_def.h`, `include/filesystem.h`, `src/filesystem.c` |
| Map-matrix member layout (width/height, optional headers & altitudes, model IDs) | `libs/assets/src/MapMatrix.lua` | `pret/pokeheartgold`: `src/map_matrix.c`, `include/map_matrix.h` |
| Area-data member layout (texture packs, dynamic texture, area/light type) | `libs/assets/src/AreaData.lua` | `pret/pokeheartgold`: `src/fielddata.c`, `include/fielddata.h` |
| Land-data container (BGS, permissions, buildings, model, BDHC) | `libs/assets/src/LandData.lua` | `pret/pokeheartgold`: `src/land_data.c`, `include/land_data.h` |
| `NNSG3dResMatData` fixed prefix (item tag, size, color words, polygon attributes, texture params, flags, original size) | `libs/assets/src/nitro/Nsbmd.lua` | NitroSDK `res_struct.h` (`NNSG3dResMatData`), GBATEK "GX 3D" for `POLYGON_ATTR`, `DIF_AMB`, `SPE_EMI` packing |
| DS geometry-engine display list | `libs/assets/src/nitro/GxDisplayList.lua` | GBATEK "DS Video Geometry Commands" |
| HGSS field-light profile text format and `lightTypeRaw` → profile mapping | `libs/assets/src/FieldLightProfile.lua`, `libs/assets/src/HgssFieldLighting.lua` | `pret/pokeheartgold`: `src/field_light.c`, `include/field_light.h`; profile tables under `data/area*light.txt` |
| Accepted ROM SHA-1s and game codes | `libs/rom/src/GameVersion.lua` | `pret/pokeheartgold`: `README.md` (canonical US hashes) |

## Refreshing the NARC catalog

`data/manifests/narc_catalog.lua` is generated, not hand-edited. To regenerate it
against a newer decomp checkout:

```sh
scripts/sync-narc-catalog.sh /path/to/pokeheartgold <commit>
```

The tool reads `include/filesystem_files_def.h`, asserts the `NarcId` enum is
contiguous from zero and that the enum count equals the path count, and emits a
deterministic catalog recording the source commit. A decomp checkout is a
developer convenience only — it is never required to run, build, or test the app,
and the app never invokes Git.

To avoid work-in-progress decomp changes silently altering runtime behavior, the
committed catalog is the source of truth: runtime reads only the checked-in
`narc_catalog.lua`, and updates land through an explicit, reviewed regeneration
with the commit recorded above.
