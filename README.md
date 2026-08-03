# g4recomp

A LÖVE 11.5 project that imports a legally-owned Nintendo DS Pokémon
**HeartGold** or **SoulSilver** ROM, dumps its NitroFS filesystem into a private
per-user cache, and reads game data from that dump at runtime.

> **This is not an emulator and does not recompile DS machine code.** It is a
> pure-Lua reader for the Nintendo DS cartridge container (header, FAT, FNT,
> overlay tables) and the HGSS NARC archive format. The current milestone ends
> at a **data diagnostic**, not a playable game.

## Legal / ROM requirement

You must supply your own ROM. g4recomp ships **no** copyrighted ROM data,
dialogue, graphics, models, or audio. Only the canonical US HeartGold and
SoulSilver dumps (verified by SHA-1) are accepted. The importer writes only
private, ROM-derived data into LÖVE's per-user save directory and releases the
ROM bytes after import.

## Requirements

- [LÖVE 11.5](https://love2d.org/)

No LuaRocks packages, no native modules, no network access.

## Running

Use the scripts in `scripts/` — they redirect the cache into a gitignored
in-repo folder during development:

```sh
scripts/run.sh                  # boot: import screen, or diagnostics if a cache is ready
scripts/test.sh                 # run the synthetic test suite
```

You can also drag-and-drop a `.nds` file onto the window to import it.

### Headless / automation

The importer runs without interaction, windowless, and exits with a status
code, so agents and scripts can drive it. The version (HeartGold/SoulSilver) is
detected from the ROM's SHA-1 — you never name it:

```sh
scripts/import.sh /path/to/pokeheartgold.us.nds   # import, exit 0 on success
scripts/import.sh /path/to/pokeheartgold.zip      # a .zip works too (see below)
```

A `.zip` can be given instead of a `.nds`: it is mounted in memory and walked
for a compatible `.nds` (matched by SHA-1), so archives with a readme or other
junk alongside the ROM just work. The same applies to drag-and-drop.

Underlying flags:

```text
--import-rom <path>   --import-only
--check-dump          # verify every ready dump using only the cache (no ROM); exits 0/1
--test
```

`--test`, `--import-only`, and `--check-dump` run windowless (no GUI). An
explicitly imported ROM is always dumped fresh; boot-time reuse of an existing
cache happens automatically without re-reading the ROM.

### Cache location

The private cache lives in LÖVE's per-user save directory by default. Set
`G4RECOMP_SAVE_DIR` to relocate it — the committed `.envrc` points it at a
gitignored `./.cache` for development, and `scripts/lib.sh` applies it. This is
the single knob a future portable mode will build on.

### Real-ROM integration test

Not run in CI (needs a legally-obtained dump). Imports the ROM, then audits the
dump in a **separate process that never opens the ROM**:

```sh
scripts/integration.sh /path/to/pokeheartgold.us.nds
```

### Regenerating the NARC catalog (developer-only)

```sh
scripts/sync-narc-catalog.sh /path/to/pokeheartgold <commit>
```

## Status

Vertical slice in progress: repository bootstrap, binary foundation, version and
cache contracts, NDS/NitroFS/NARC parsing, private dump, and a runtime `RomFs`
diagnostic. See [`docs/architecture.md`](docs/architecture.md) for the boot,
import, and runtime design, and [`docs/data-provenance.md`](docs/data-provenance.md)
for where each parsed structure comes from.
