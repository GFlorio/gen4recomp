# Architecture

g4recomp turns a legally-owned Nintendo DS **HeartGold** or **SoulSilver** ROM
into a private, on-disk filesystem dump, then reads game data from that dump at
runtime. This document covers the boot/import/runtime flow, the split between the
raw dump and future derived data, and the three ID namespaces the code keeps
strictly apart.

## Layers

The code follows three layers. The domain layer is pure and testable without
LÖVE; interface and infrastructure are allowed to depend on LÖVE and are kept
thin.

| Layer | Modules | LÖVE? |
| --- | --- | --- |
| **Domain — pure parsers/decoders** | `BinaryReader`, `NdsRom`, `NitroFs`, `OverlayTable`, `Narc`, `MapMatrix`, `AreaData`, `LandData`, `Nsbmd`, `Nsbtx`, `GxDisplayList`, `DsMaterial`, `DsPolygonAttr`, `FieldLightProfile`, `DsLighting`, `RenderQueue`, `LuaWriter`, `Errors`, `GameVersion` | no |
| **Infrastructure** | `RomSource` (owns the ROM bytes, SHA-1), `CacheFs` (private per-version storage), `RomExtractor` (dump orchestration), `RomFs` (runtime read API), `DumpAudit`, `MapAssetCompiler`, `MapCacheWriter`, `MapAssetCache` | `RomSource`/`CacheFs` only |
| **Interface** | `App` (dispatch/boot), `Cli` (flag parsing, pure), `RomImporter` (state machine + coroutine), `MapSceneLoader`, `MapRenderer`, `Gizmos`, `Camera3D`, `ui/*` states | yes |

The pure parsers never touch LÖVE, never read a file, and never mutate global
state — they take a byte string and return a validated structure or a structured
`Errors` object. Anything that reads or writes the disk goes through `RomSource`
(the ROM) or `CacheFs` (the private cache).

## Boot flow

`main.lua` parses flags with `Cli`, then hands off to `App`:

```
love.load
  └─ Cli.parse(argv)
       ├─ --test          → run the synthetic suite, exit 0/1
       ├─ --import-rom P   → App starts an import of P (headless if --import-only)
       └─ (no rom)         → App inspects both version caches:
                              0 ready → import screen
                              1 ready → that version's diagnostic
                              2 ready → version selector → diagnostic
```

`--check-dump` is a headless verification path: it audits every ready cache with
`DumpAudit` using only `RomFs`, never opening the ROM, and exits 0/1.

## Import flow

Import is a state machine (`RomImporter`) driven one step per frame inside a
coroutine so the UI stays responsive. Validation always completes **before** any
cache is touched:

```
idle → reading → verifying → extracting → complete
                                        ↘ error
```

1. **reading** — open the source (`RomSource.fromPath` / `fromDroppedFile`; a
   `.zip` is mounted in memory and walked for a compatible `.nds`).
2. **verifying** — compute the full SHA-1, resolve the version from it
   (`GameVersion.forSha1`), parse and validate the NDS header, and confirm the
   game code. An unknown hash is rejected here, before any write.
3. **extracting** — `RomExtractor` runs its stages: write the system section
   (header/FNT/FAT/ARM/overlay tables), dump every FAT file to its resolved
   path, write the metadata indexes, resolve and open the required NARCs,
   smoke-decode map matrix member 0, then write the completion marker **last**.
4. **complete/error** — the ROM bytes are released (`RomSource:release`) and a
   single garbage collection runs on every terminal state.

The completion marker (`rom-dump.complete`, content
`g4-rom-dump-v1:<version>:<sha1>`) is the definition of a ready cache. A partial
dump without the exact marker is never treated as ready, and a retry removes only
the selected version's subtree — importing one game never touches the other.

## Runtime flow

Once a cache is ready, the runtime never needs the ROM again. `RomFs.open` loads
the generated Lua metadata through `CacheFs`, validates its schema, and builds
transient path/alias lookups in memory. Reads are lazy: no payload is loaded
until requested. `DiagnosticState` is the current end of the slice — it opens
the `map_matrices` NARC, reads member 0, and decodes it with `MapMatrix` purely
through `RomFs`:

```lua
local romFs = assert(RomFs.open(versionId))
local matrices = assert(romFs:openNarc("map_matrices"))
local matrix = assert(MapMatrix.decode(matrices:readMember(0), 0))
```

## Raw dump vs. derived data

The cache separates two concerns so future format work never forces a re-import:

- **Raw dump** — a lossless, byte-for-byte copy of every FAT-backed file under
  `romfs/` and `system/`, plus generated indexes. Its layout is versioned by
  `ROM_DUMP_FORMAT`; only a layout or index-schema change bumps it and requires
  re-importing.
- **Derived data** (future) — decoded formats (models, text, Pokémon data) will
  be built *from* the raw dump and carry their own separate cache marker.
  Changing a decoder must never invalidate `rom-dump.complete`.

This is why the dump is kept lossless and unnormalized: the ROM is presented
once, and every later format iteration works from the private dump.

## The three ID namespaces

These are unrelated indices and are never conflated. No module exposes a bare
`id` where more than one could apply.

| Name | Meaning | Source |
| --- | --- | --- |
| `narcId` | Index into HGSS's `NarcId` enum / `sNarcFileList` | decompilation metadata |
| `fileId` | Index into the NDS cartridge FAT | parsed from the ROM |
| `memberId` | Index into one NARC's member FAT | parsed from the NARC |

A path like `a/0/4/1` is resolved through the parsed FNT to a `fileId`. The fact
that the decompilation labels it `NARC_fielddata_mapmatrix_map_matrix` with
`narcId = 41` does **not** mean `narcId == fileId` — the catalog gives semantic
names, the ROM's FNT/FAT gives physical paths and file IDs, and the latter is
authoritative for anything physical. All offsets, file IDs, and member IDs are
**zero-based** on disk and in memory; zero-based maps are iterated
`for id = 0, count - 1`, never with `ipairs`.

See [data-provenance.md](data-provenance.md) for where each structure comes from
and [rom-import.md](rom-import.md) for how to import and verify a dump.
