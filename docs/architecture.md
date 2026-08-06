# Architecture

g4recomp turns a legally-owned Nintendo DS **HeartGold** or **SoulSilver** ROM
into a private, on-disk filesystem dump, then reads game data from that dump at
runtime. This document covers the boot/import/runtime flow, the split between the
raw dump and future derived data, and the three ID namespaces the code keeps
strictly apart.

## Repository layout

The repository is a small monorepo: top-level directories are applications you
run; `libs/` holds the capabilities they share. Each app is its own LÖVE root.

```text
game/         Interactive app — launcher, boot, and the 3D map diagnostic (love game/)
romdump/      Headless ROM/asset CLI — import, audit, inspect, compile (love romdump/)
libs/rom/     NDS/NitroFS/NARC formats, binary reading, ROM validation, dump filesystem
libs/assets/  HGSS data decoding, map/mesh/material compilation, derived-cache formats
libs/engine/  Rendering, cameras, scenes, collision/world primitives
data/         Frozen references and runtime manifests
tests/        Aggregate + private-target runners and shared fixtures (tests/support)
```

Unit tests live beside their library under `libs/<lib>/tests`; `tests/run.lua`
is the aggregate list the runner iterates. An app's `main.lua` adds the repo
root (its LÖVE source base directory) to `package.path`, so every module is
required by its full repo-relative path — `libs.rom.src.NdsRom`,
`game.src.game.App`, `data.manifests.hgss`.

## Layers

Cutting across that layout, the code follows three conceptual layers. The domain
layer is pure and testable without LÖVE; interface and infrastructure are
allowed to depend on LÖVE and are kept thin. `libs/rom` and `libs/assets` are
overwhelmingly domain; `libs/engine` and the app `src/` trees are interface.

| Layer | Modules | LÖVE? |
| --- | --- | --- |
| **Domain — pure parsers/decoders** | `BinaryReader`, `NdsRom`, `NitroFs`, `OverlayTable`, `Narc`, `MapMatrix`, `AreaData`, `LandData`, `Nsbmd`, `Nsbtx`, `GxDisplayList`, `DsMaterial`, `DsPolygonAttr`, `FieldLightProfile`, `DsLighting`, `RenderQueue`, `LuaWriter`, `Errors`, `GameVersion` | no |
| **Infrastructure** | `RomSource` (owns the ROM bytes, SHA-1), `CacheFs` (private per-version storage), `RomExtractor` (dump orchestration), `RomFs` (runtime read API), `DumpAudit`, `MapAssetCompiler`, `MapCacheWriter`, `MapAssetCache` | `RomSource`/`CacheFs` only |
| **Interface** | `game` `App` (dispatch/boot), `romdump` `Cli` (flag parsing, pure) + `Runner` (headless commands), `RomImporter` (state machine + coroutine), `MapSceneLoader`, `MapRenderer`, `Gizmos`, `FieldCamera`, `FieldViewport`, the `game/src` UI states | yes |

The pure parsers never touch LÖVE, never read a file, and never mutate global
state — they take a byte string and return a validated structure or a structured
`Errors` object. Anything that reads or writes the disk goes through `RomSource`
(the ROM) or `CacheFs` (the private cache).

## Boot flow

The interactive `game/main.lua` parses its flags inline, then hands off to
`App`:

```
love game/
  └─ love.load(argv)
       ├─ --test / --test-private → run a suite, exit 0/1
       ├─ --map ID                → boot straight into the 3D map diagnostic
       ├─ --actors                → boot the compiled field-actor preview grid
       └─ (no flags)              → App inspects both version caches:
                                     0 ready → import screen
                                     1 ready → that version's diagnostic
                                     2 ready → version selector → diagnostic
```

The headless `romdump/main.lua` parses with `Cli` and dispatches to `Runner`,
which drives `libs/rom` and `libs/assets` and exits with a status code:

```
love romdump/
  └─ Runner.load(Cli.parse(argv))
       ├─ --import-rom P [--import-only] → import P (version detected from SHA-1)
       ├─ --check-dump                   → audit every ready cache with DumpAudit,
       │                                   using only RomFs, never opening the ROM
       ├─ --analyze-maps                 → derive map-cell resolution inventory
       ├─ --inspect                      → payload-free inventory of every renderable map
       ├─ --inspect-actors               → payload-free inventory of the compiled actor set
       └─ --build-cache [P] [--forcedump P]
                                           → reuse a ready dump, import P if none exists,
                                             or forcibly redump P;
                                             clear and rebuild all game-facing data
```

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

`world.lua` records the two kinds of omission separately, because they call for
different work: `analysis.excluded` holds map headers whose matrix cell could not
be selected, and `analysis.compileExcluded` holds resolved maps whose asset
compilation raised a structured error, each with its `errorCode`, `message`, and
`context`. A compile failure writes no partial map — `MapCacheWriter` commits the
completion marker only after the whole bundle succeeds — and makes
`scripts/buildcache.sh` exit nonzero so the gap stays visible to CI;
`--allow-compile-exclusions` accepts it for an exploratory run. A programming
error still aborts the build outright.

## Runtime flow

Once a cache is ready, the runtime never needs the ROM again, and it never
decodes a raw ROM format directly — everything comes from the derived cache
that `scripts/buildcache.sh` wrote. `game`'s `MapDiagnosticState` loads the cache's
`world.lua` manifest through `CacheFs`, resolves the requested map with
`WorldLookup`, and loads that map's `scene.lua` through `MapSceneLoader`:

```lua
local world = assert(cacheFs:loadLua(MapAssetCache.worldPath()))
local map = WorldLookup.require(world, idOrSymbol)
local scene = assert(cacheFs:loadLua(MapAssetCache.mapDir(map.id) .. "/scene.lua"))
local runtime = MapSceneLoader.load(cacheFs, scene)
```

### Field actors

`FieldState` owns the actor chain and wires it into the fixed-step session:

```text
FieldEventState  (numeric flags/vars; the visibility authority)
  └─ FieldActorManager  (object actors + the occupancy index, one per live map)
       ├─ FieldObjectActor   (immutable source event, mutable runtime state)
       └─ FieldActorAssetProvider  (shared compiled visuals, acquire/release)
```

An object exists only while its event flag is clear, matching the original
engine. Flag writes are queued and applied at one point in the fixed tick —
before movement reads occupancy — so the draw list and collision never disagree
within a tick. Actors in this milestone are static: a movement code outside the
verified static set is preserved on the actor and reported once through the
developer trace, never executed. `data/manifests/field_scenario.lua` seeds which
target objects start hidden; it names objects by map/object identity and
`FieldScenario` resolves each to the ROM's numeric flag.

## Raw dump vs. derived data

The cache separates two concerns so future format work never forces a re-import:

- **Raw dump** — a lossless, byte-for-byte copy of every FAT-backed file under
  `romfs/` and `system/`, plus generated indexes. Its layout is versioned by
  `ROM_DUMP_FORMAT`; only a layout or index-schema change bumps it and requires
  re-importing.
- **Derived data** — decoded formats built *from* the raw dump, each an
  independently rebuildable class with its own completion marker: compiled maps
  (`data/generated/maps`), field cameras (`data/generated/field/camera`), field
  map data (`data/generated/field/maps`), and field-actor visuals
  (`data/generated/field/actors` plus `assets/generated/field/actors`). Changing
  one decoder rebuilds only its class and must never invalidate
  `rom-dump.complete`. Text and Pokémon data follow the same pattern.

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
