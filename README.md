# g4recomp

A LÖVE 11.5 project that imports a legally-owned Nintendo DS Pokémon
**HeartGold** or **SoulSilver** ROM, dumps its NitroFS filesystem into a private
per-user cache, and reads game data from that dump at runtime.

> **This is not an emulator and does not recompile DS machine code.** It is a
> pure-Lua reader for the Nintendo DS cartridge container (header, FAT, FNT,
> overlay tables) and the HGSS NARC archive format. The project currently
> delivers an interactive field runtime over the compiled assets — walkable maps,
> deterministic movement and collision, warps, object interactions, and modal
> dialogue — not a playable game.

## Legal / ROM requirement

You must supply your own ROM. g4recomp ships **no** copyrighted ROM data,
dialogue, graphics, models, or audio. Only the canonical US HeartGold and
SoulSilver dumps (verified by SHA-1) are accepted. The importer writes only
private, ROM-derived data into LÖVE's per-user save directory and releases the
ROM bytes after import.

## Requirements

- [LÖVE 11.5](https://love2d.org/)

No LuaRocks packages, no native modules, no network access.

To contribute you also need [stylua](https://github.com/JohnnyMorganz/StyLua) and
[lua-language-server](https://github.com/LuaLS/lua-language-server) on your
`PATH` (both ship in the dev container). Then run `scripts/repo-setup.sh` once
to point git at the committed hooks — git never installs hooks on clone. CI runs
the same checks as the hook, so bypassing it only defers the failure.

## Running

Use the scripts in `scripts/` — they redirect the cache into a gitignored
in-repo folder during development:

```sh
scripts/run.sh                  # boot: import screen, or the field runtime if a cache is ready
scripts/buildcache.sh [ROM]     # import if needed, then rebuild the game cache
scripts/test.sh                 # run every available test layer (--list, --layer, --filter, --rom-source)
scripts/lint.sh                 # stylua --check + lua-language-server diagnostics
```

You can also drag-and-drop a `.nds` file onto the window to import it.

### Headless / automation

The cache builder runs without interaction, windowless, and exits with a status
code. It reuses an existing raw dump. If none is available, supply a ROM and its
version (HeartGold/SoulSilver) is detected from the SHA-1:

```sh
scripts/buildcache.sh /path/to/pokeheartgold.us.nds
scripts/buildcache.sh /path/to/pokeheartgold.zip
```

A `.zip` can be given instead of a `.nds`: it is mounted in memory and walked
for a compatible `.nds` (matched by SHA-1), so archives with a readme or other
junk alongside the ROM just work. The same applies to drag-and-drop.

Once a dump exists, no ROM argument is needed. Every invocation rebuilds the
derived cache consumed by `game`, recompiling only what is stale — a map or
class whose completion marker already matches the current build is left in
place:

```sh
scripts/buildcache.sh
```

To replace an existing raw dump before rebuilding, pass the ROM explicitly:

```sh
scripts/buildcache.sh --forcedump /path/to/pokeheartgold.us.nds
```

### Cache location

The private cache lives in LÖVE's per-user save directory by default. Set
`G4RECOMP_SAVE_DIR` to relocate it — the committed `.envrc` points it at a
gitignored `./.cache` for development, and `scripts/lib.sh` applies it. This is
the single knob a future portable mode will build on.

### Real-ROM run

Not run in CI (needs a legally-obtained dump). Imports the ROM and builds its
derived cache in an isolated save root, then runs the whole suite against it:

```sh
scripts/integration.sh /path/to/pokeheartgold.us.nds   # = scripts/test.sh --rom-source ...
```

With an already-imported dump, plain `scripts/test.sh` prepares the derived
cache and runs the ROM-gated layer too; without one it runs the ROM-independent
layers and reports the ROM-gated tests as skipped.

## Status

Vertical slice complete through DS material/lighting, 3D map rendering, and the
interactive field runtime: repository bootstrap, binary foundation, version and
cache contracts, NDS/NitroFS/NARC parsing, private dump, runtime `RomFs`,
map/building model compilation, DS vertex lighting, deterministic field
movement and collision, warps, object interactions, and modal dialogue. See
[`docs/architecture.md`](docs/architecture.md) for the boot/import/runtime design,
[`docs/data-provenance.md`](docs/data-provenance.md) for where each parsed
structure comes from, and [`docs/rendering.md`](docs/rendering.md) for the
material, lighting, and render pipeline.
