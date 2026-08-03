# ROM import & local integration test

The synthetic test suite (`scripts/test.sh`) never touches a real ROM and is the
only thing CI runs. This document covers the **manual, local** integration test
against a real cartridge dump — the check that a genuine HeartGold/SoulSilver ROM
imports, verifies, and boots from cache alone. It is never run in public CI
because it needs a legally-obtained ROM you supply yourself.

## One-shot integration script

```sh
scripts/integration.sh /path/to/your.nds
```

This imports the ROM headlessly, then, in a **separate process that never opens
the ROM**, audits every ready dump. Any failure exits nonzero. The version
(HeartGold or SoulSilver) is detected from the ROM's SHA-1 — you never name it.
A `.zip` containing the `.nds` works too; it is mounted in memory and walked for
a compatible ROM.

## Manual steps

Run the same two phases by hand to inspect the results:

```sh
# 1. Import (windowless, exit 0 on success). Version detected from SHA-1.
scripts/import.sh /path/to/your.nds

# 2. Verify every ready dump using only the private cache — no ROM.
love . --check-dump
```

Then confirm the "boots without the ROM" guarantee end to end:

```sh
# 3. Move the ROM away and re-audit. It must still pass.
mv /path/to/your.nds /somewhere/else.nds
love . --check-dump

# 4. Launch interactively; with a ready cache this boots straight into the
#    data diagnostic (or a version selector if both games are imported).
scripts/run.sh
```

### What a good run shows

- The correct version is detected purely by SHA-1.
- The completion marker `rom-dump.complete` exists for that version.
- Every FAT entry has an index row and exactly one output file, each sized to
  the FAT `end - start` range.
- The required NARC aliases (`personal`, `moves`, `messages`, `map_matrices`)
  resolve and open as NARCs.
- Map-matrix member 0 decodes, and the diagnostic shows its name, dimensions,
  and model-cell count.
- Importing both games leaves two independent caches that never collide.

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
│   │                                #   resolved_narcs, import_report (Lua)
│   ├── romfs/                        # every named NitroFS file at its exact path
│   │   └── a/0/4/1  …  data/sound/gs_sound_data.sdat
│   └── system/                      # header.bin, fnt.bin, fat.bin, arm9/arm7,
│       ├── overlay9/overlay_<id>.bin#   overlay tables, and per-overlay files
│       ├── overlay7/overlay_<id>.bin
│       └── unmapped/file_<id>.bin   # FAT entries with no FNT name or overlay
└── soulsilver/
    └── … same layout
```

## Clearing one version's cache

Each version is self-contained, so removing one never affects the other. Delete
that version's subtree under the save directory:

```sh
rm -rf "<save-dir>/heartgold"     # or soulsilver
```

LÖVE appends `love/<identity>` to its base directory, so the save directory is:

- **Linux (default):** `~/.local/share/love/g4recomp`
- **Dev (`.envrc` sets `G4RECOMP_SAVE_DIR=$PWD/.cache`):** `.cache/love/g4recomp`

In the default dev setup that is simply:

```sh
rm -rf .cache/love/g4recomp/heartgold
```

A fresh import also clears its own version's partial output first (marker
removed before anything is written), so re-importing is always safe; you only
need to delete a subtree if you want to force a version back to the import
screen.
