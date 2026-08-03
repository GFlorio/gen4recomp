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

```sh
love .                          # boot: import screen, or diagnostics if a cache is ready
love . --import-rom /path/to/pokeheartgold.us.nds
love . --test                   # run the synthetic test suite
```

You can also drag-and-drop a `.nds` file onto the window to import it.

## Status

Vertical slice in progress: repository bootstrap, binary foundation, version and
cache contracts, NDS/NitroFS/NARC parsing, private dump, and a runtime `RomFs`
diagnostic. See `tmp/spec.md` for the full specification.
