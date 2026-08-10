# ROM import & local integration test

`scripts/test.sh` is the single test command: its ROM-independent layers are the
only thing CI runs, and its ROM-gated layers run whenever a dump is ready. This
document covers the **manual, local** path against a real cartridge dump — the
check that a genuine HeartGold/SoulSilver ROM imports, verifies, and boots from
cache alone. It is never run in public CI because it needs a legally-obtained ROM
you supply yourself.

## One-shot source-ROM script

```sh
scripts/integration.sh /path/to/your.nds
```

This imports the ROM headlessly and builds its derived cache in an isolated save
root that never touches your ordinary cache, then runs the whole suite against
it (`scripts/test.sh --rom-source`). Any failure exits nonzero. The version
(HeartGold or SoulSilver) is detected from the ROM's SHA-1 — you never name it.
A `.zip` containing the `.nds` works too; it is mounted in memory and walked for
a compatible ROM.

## Build the game cache

One command imports a ROM when necessary and rebuilds all derived data used by
the game — classes whose completion markers already match are skipped, so an
unchanged cache rebuilds only what is stale:

```sh
scripts/buildcache.sh /path/to/your.nds
```

Once the raw dump exists, omit the ROM path:

```sh
scripts/buildcache.sh
```

Force a fresh dump from the ROM before rebuilding with:

```sh
scripts/buildcache.sh --forcedump /path/to/your.nds
```

Then confirm the "boots without the ROM" guarantee end to end:

```sh
# Move the ROM away and audit. It must still pass.
mv /path/to/your.nds /somewhere/else.nds
love romdump/ --check-dump

# Launch interactively; with a ready cache this boots straight into the
#    field runtime (or a version selector if both games are imported).
scripts/run.sh
```

### What a good run shows

- The correct version is detected purely by SHA-1.
- The completion marker `rom-dump.complete` exists for that version.
- Every FAT entry has an index row and exactly one output file, each sized to
  the FAT `end - start` range.
- The required NARC aliases (`personal`, `moves`, `messages`, `map_matrices`)
  resolve and open as NARCs.
- Map-matrix member 0 decodes, and the map list shows its name, dimensions,
  and model-cell count.
- Importing both games leaves two independent caches that never collide.

## Import safety

An import extracts into a disposable staging namespace and only then publishes
the completed tree over the live version root, so re-importing a version never
destroys a previously working dump mid-way:

1. The ROM identity is validated (SHA-1, header, game code) before anything is
   written.
2. Any stale staging output from a previous attempt is removed.
3. The dump is extracted completely into `staging/<version>/`, with every
   readback/smoke check performed against the staged tree.
4. The completion marker is written last, inside staging.
5. The staged tree is published over the live root in two renames, with a
   rollback if the second rename cannot land; only after it lands is the
   previous dump removed.

A failed extraction or failed publish therefore leaves the previous ready dump
usable, and a partial staged dump never exposes its marker. `RomImporter.isReady`
only ever looks at the live version root, so leftover staging can never make a
version look ready.

## Cache location & layout

The private cache lives in LÖVE's per-user save directory under identity
`g4recomp`. During development the committed `.envrc` points `G4RECOMP_SAVE_DIR`
at a gitignored in-repo `./.cache`, and `scripts/lib.sh` applies it; unset it to
use the OS default. This single knob is the seam a future portable mode will
reuse.

Each version gets its own subtree so the two games never interfere:

```
<save-dir>/
├── heartgold/
│   ├── rom-dump.complete            # marker: g4-rom-dump-v1:heartgold:<sha1>
│   ├── data/generated/              # rom_metadata, romfs_index, overlay_index,
│   │                                #   import_report (Lua). NARC aliases are
│   │                                #   resolved at runtime, not baked here.
│   ├── romfs/                        # every named NitroFS file at its exact path
│   │   └── a/0/4/1  …  data/sound/gs_sound_data.sdat
│   └── system/                      # header.bin, fnt.bin, fat.bin, arm9/arm7,
│       ├── overlay9/overlay_<id>.bin#   overlay tables, and per-overlay files
│       ├── overlay7/overlay_<id>.bin
│       └── unmapped/file_<id>.bin   # FAT entries with no FNT name or overlay
├── soulsilver/
│   └── … same layout
├── staging/                          # disposable staging for imports and for
│   ├── heartgold/                    #   generated-cache rebuilds, published
│   └── soulsilver/                   #   over the live roots on success; stale
│                                      #   staging is removed at the next import
└── saves/                            # persistent user data, NOT part of any
    └── heartgold/                    #   version cache: re-imports and cache
        └── field-session-v1.lua      #   clears can never delete it
```

Persistent saves live in the sibling `saves/<version>/` namespace so every
operation that deletes or rebuilds a version cache is structurally incapable of
touching them. Imports rebuild into `staging/<version>/` first and publish only
a complete tree, so they are likewise incapable of destroying a ready dump or a
save. Derived-cache rebuilds follow the same pattern: each generated class
stages under `staging/<version>/<class>/` (`scripts/buildcache.sh` writes) and
publishes over the live roots only after its staged result validates, so a
failed rebuild leaves the previous ready artifact in place and stale derived
staging is swept with the next import.

## Clearing one version's cache

Each version is self-contained, so removing one never affects the other. Delete
that version's subtree under the save directory:

```sh
rm -rf "<save-dir>/heartgold"     # or soulsilver
```

Clearing a version cache never touches its saves under `<save-dir>/saves/`.

LÖVE appends `love/<identity>` to its base directory, so the save directory is:

- **Linux (default):** `~/.local/share/love/g4recomp`
- **Dev (`.envrc` sets `G4RECOMP_SAVE_DIR=$PWD/.cache`):** `.cache/love/g4recomp`

In the default dev setup that is simply:

```sh
rm -rf .cache/love/g4recomp/heartgold
```

A fresh import also clears its own version's stale staging first, so re-importing
is always safe and a previously interrupted import cannot leave partial output
in the live tree; you only need to delete a subtree if you want to force a
version back to the import screen.
