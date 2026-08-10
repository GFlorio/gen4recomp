# Architecture

g4recomp turns a legally-owned Nintendo DS **HeartGold** or **SoulSilver** ROM
into a private, on-disk filesystem dump, then reads game data from that dump at
runtime. This document covers the boot/import/runtime flow, the split between the
raw dump and the derived data, and the three ID namespaces the code keeps
strictly apart.

## Repository layout

The repository is a small monorepo: top-level directories are applications you
run; `libs/` holds the capabilities they share. Each app is its own LÖVE root.

```text
game/         Interactive app — launcher, boot, and the field runtime (love game/)
romdump/      Headless ROM/asset CLI — import, audit, inspect, compile (love romdump/)
libs/rom/     NDS/NitroFS/NARC formats, binary reading, ROM validation, dump filesystem
libs/assets/  Asset contracts for generated data (schemas, cache paths/readiness,
             modder-facing text forms), plus shared section readers and
             map/mesh/material compilation
libs/engine/  Rendering, cameras, scenes, collision/world primitives
data/         Frozen references and runtime manifests
tests/        Test runner (tests/runner), ROM and acceptance suites, shared fixtures (tests/support)
```

Unit tests live beside their library under `libs/<lib>/tests`; `tests/run.lua`
declares the discovery roots and their default layers, and `tests/runner/`
implements discovery, suite normalization, selection, execution, and reporting.
An app's `main.lua` adds the repo root (its LÖVE source base directory) to
`package.path`, so every module is required by its full repo-relative path —
`libs.rom.src.NdsRom`, `game.src.game.App`, `data.manifests.hgss`.

## Layers

Cutting across that layout, the code follows three conceptual layers. The domain
layer is pure and testable without LÖVE; interface and infrastructure are
allowed to depend on LÖVE and are kept thin. `libs/rom` and `libs/assets` are
overwhelmingly domain; `libs/engine` and the app `src/` trees are interface.

| Layer | Modules | LÖVE? |
| --- | --- | --- |
| **Domain — pure parsers/decoders** | `BinaryReader`, `NdsRom`, `NitroFs`, `OverlayTable`, `Narc`, `MapMatrix`, `AreaData`, `LandData`, `Nsbmd`, `Nsbtx`, `GxDisplayList`, `DsMaterial`, `DsPolygonAttr`, `FieldLightProfile`, `DsLighting`, `RenderQueue`, `LuaWriter`, `Errors`, `GameVersion` | no |
| **Infrastructure** | `RomSource` (owns the ROM bytes, SHA-1), `CacheFs` (private per-version storage), `ArtifactPublisher` (staged generated-cache publication), `RomExtractor` (dump orchestration), `RomFs` (runtime read API), `DumpAudit`, `MapAssetCompiler`, `MapCacheWriter`, `MapAssetCache` | `RomSource`/`CacheFs` only |
| **Interface** | `game` `App` (dispatch/boot), `romdump` `Cli` (flag parsing, pure) + `Runner` (headless commands), `RomImporter` (state machine + coroutine), `MapSceneLoader`, `MapRenderer`, `FieldCamera`, `FieldViewport`, the `game/src` UI states | yes |

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
       ├─ --test [options]        → run the test suite, exit 0/1/2
       ├─ --field [map]           → boot the field runtime on a target map
       ├─ --actors                → boot the compiled field-actor preview grid
       └─ (no flags)              → App inspects both version caches:
                                      0 ready → import screen
                                      1 ready → that version's field runtime
                                      2 ready → version selector → field runtime
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
                                             rebuild game-facing data, recompiling
                                             only the classes whose markers are stale
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
   All of this lands in the disposable `staging/<version>/` namespace; the
   completed staged tree is then published over the live version root in two
   renames (with rollback if the second rename fails), and only after it lands
   is the previous dump removed. A failed extraction or publish leaves the
   previous ready dump untouched and usable.
4. **complete/error** — the ROM bytes are released (`RomSource:release`) and a
   single garbage collection runs on every terminal state.

The completion marker (`rom-dump.complete`, content
`g4-rom-dump-v1:<version>:<sha1>`) is the definition of a ready cache. It is
written only inside a fully validated staged tree, and `RomImporter.isReady`
reads only the live version root — a partial dump, staged or stale, is never
treated as ready. Importing one game never touches another version's subtree or
the sibling `saves/` namespace.

`world.lua` records the two kinds of omission separately, because they call for
different work: `analysis.excluded` holds map headers whose matrix cell could not
be selected, and `analysis.compileExcluded` holds resolved maps whose asset
compilation raised a structured error, each with its `errorCode`, `message`, and
`context`. A compile failure writes no partial map — `MapCacheWriter` stages the
map's subtree and commits the completion marker only after the whole bundle
succeeds, and a failed rebuild leaves the previous ready map in place — and
makes `scripts/buildcache.sh` exit nonzero so the gap stays visible to CI;
`--allow-compile-exclusions` accepts it for an exploratory run. A programming
error still aborts the build outright.

## Runtime flow

Once a cache is ready, the runtime never needs the ROM again, and it never
decodes a raw ROM format directly — everything comes from the derived cache
that `scripts/buildcache.sh` wrote. `FieldState` is the normal runtime
coordinator: it loads the cache's `world.lua` manifest and the per-map visual,
field-data, and terrain artifacts through `FieldMapLoader`, which joins them
into the `RuntimeFieldMap` the player, camera, and renderer consume. A loaded
map stays resident under the loader's LRU policy while warps, actor
occupancy, and coverage keep working from the derived data alone.

### Runtime/presentation boundary and acceptance

`FieldRuntime` owns non-rendering field behavior: real derived-cache loading,
maps, player and actors, scripts, dialogue control, input, transitions, saves,
and deterministic camera state. `FieldPresentation` owns the LÖVE-only renderer,
GPU assets, viewport, and dialogue rendering. Interactive `FieldState` composes
both; the acceptance layer boots `FieldRuntime` through its production harness
with recording host adapters and an isolated save root, then stops before any
GPU draw call. This keeps user-flow coverage on the real composition path while
graphics smoke tests separately own actual shader, canvas, mesh, and image work.

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
within a tick. An actor's raw ROM movement code is preserved on the actor and
never executed; actors move only through script movement tasks.
`data/manifests/field_scenario.lua` seeds which target objects start hidden; it names objects by map/object
identity and `FieldScenario` resolves each to the ROM's numeric flag.

The player's movement decision order is permissions, then terrain surface
transition, then actor occupancy (`FieldPlayer` consults the manager's
occupancy index through an injected predicate that returns the blocking
actor's id, keyed by the resolved destination surface), then the move commits.
Because the warp checks run before a move starts in `FieldSession`, a visible
actor can never block a facing-warp trigger; a walkable warp cell with an actor
standing on it blocks the step, matching the original engine's behavior.

### Interaction discovery

`FieldSession` resolves an idle player's Action edge before movement and warps,
through services that `FieldState` wires together:

```text
FieldInteractionResolver  (pure; object-first, background-second priority)
  -> InteractionIntent   (immutable; raw scriptId + script bank carried)
  -> ScriptInteractionClient      (binding -> composed script on the scheduler)
  -> PreScriptInteractionAdapter  (fallback: fixture match -> dialogue request)
  -> FieldDialogueController      (modal input ownership)
```

The resolver mirrors `pret/pokeheartgold`'s field-control order: the facing
object actor from the occupancy index wins, then a source-order background
event whose raw direction passes the pinned assembly's compatibility table
(raw 4 wildcard; 0/1/2/3 accept {0,6}/{3,6}/{2,5}/{1,5}), then nothing.
Type-2 background events (hidden items) are skipped because their collection
flags are not tracked yet. A resolved intent goes first to
`ScriptInteractionClient`, which looks the intent up in the bindings manifest,
composes the bound script, and starts it as the foreground root on the scheduler
so it runs during the trigger tick. An intent with no binding falls through to
`PreScriptInteractionAdapter`, the fixture client that remains until every
interaction is bound: it matches intents against
`data/manifests/pre_script_interactions.lua`, formats the fixture message
through `FieldMessageProvider`, pushes a temporary face-player override that
every terminal dialogue path releases exactly once, and opens the modal
dialogue.

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

Every derived class publishes through the same staged publication primitive
(`ArtifactPublisher`): the class's writers stage all new files under a
disposable `staging/<version>/<name>/` root, validate the staged result, and
only then swap it over the live roots with the completion marker last. A failed
rebuild therefore never destroys the previous ready artifact, and a failed
publish rolls every moved root back. The marker-last write is what proves a
staged tree complete; the replacement guarantee comes from the stage/validate/
publish sequence around it, not from the marker alone. Map caches share content-addressed
geometry/textures across maps, so only the map's own subtree is swapped; the
shared content is written in place and is idempotent by content addressing.

This is why the dump is kept lossless and unnormalized: the ROM is presented
once, and every later format iteration works from the private dump.

## Digestion, assets, and the game

Derived data crosses three roles, each with a hard rule. The message/font
classes are the reference implementation of the split; the map classes still
carry their section readers in `libs/assets` and are the planned follow-up.

| Role | Owner | Rule |
| --- | --- | --- |
| **Digestion** | `romdump/src/digest` — raw-byte decoders (MAT decryption, tile bit-packing, charmap mapping) and the compilers that emit artifacts | every ROM-byte interpretation happens here: NARC members in, generated artifacts out. Nothing else may know a MAT header, a 2bpp tile layout, or a code unit |
| **Asset contract** | `libs/assets/src` — artifact schemas, cache paths/readiness, modder-facing text forms (`FieldMessageText`) | generated artifacts are presented as traditional game assets — for text, a display string with metadata — and the contract is stable, documented, and modder-facing |
| **Game** | `libs/engine` + `game/src` — runtime models and behavior | operates only on the asset level: message banks are text with a lossless token stream, fonts are atlases with metrics. No NARC/member parsing, no ROM access, no decomp-derived reference imports |

The message/font classes follow it strictly: `romdump` digests msgdata MAT
members and font tiles into bank artifacts whose messages are
`{ id, text, tokens, raw }` with GMM-style markers (`{STRVAR_1 3, 0, 0}`), and
a font definition that carries its own charmap metadata; the runtime renders,
formats, and substitutes text without ever seeing a code unit or importing the
frozen charmap reference. Markers are a first-class API (`FieldMessageText`:
constants, `marker()`, `parse()`, `tokensToText()`), so mods can read and write
the text form directly.

The map classes are the known exception: section readers such as
`PermissionGrid`, `HgssBdhc`, and `MapMatrix` live in `libs/assets` and are
shared by the importer (which extracts and validates the sections) and the
runtime (which decodes the artifact bytes at map load). Moving their raw
readers into `romdump/src/digest` — leaving `libs/assets` with only the
artifact-format readers the runtime genuinely needs — is the planned follow-up
so the boundary is uniform.

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
