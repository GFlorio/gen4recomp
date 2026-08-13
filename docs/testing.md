# Testing

`scripts/test.sh` is the only test command. It recursively discovers suites,
selects layers, checks the ready dump's derived cache when needed, and reports
passes, failures, skips, capabilities, and timings.

## Layers

| Layer | Contract | Data and rendering |
| --- | --- | --- |
| Unit | One module or small pure graph | Synthetic; no rendering |
| Component | Several production collaborators | Synthetic fixtures or temporary files |
| Graphics | Real LÖVE graphics smoke | Tiny synthetic assets; offscreen GPU work |
| ROM | Parser, compiler, and corpus conformance | Ready user-owned dump; no rendering |
| Acceptance | User-visible production field flow | Ready dump plus derived cache; stops before drawing |
| ROM-source E2E | Isolated import through acceptance boot | User-supplied `.nds` or `.zip`; stops before drawing |

Graphics capability is required for the default suite. A graphics setup failure
is infrastructure failure, never a pass or skip. ROM data is private: do not
commit dumps, extracted files, derived commercial assets, or copied text.

## Commands and ROM policy

```sh
scripts/test.sh
scripts/test.sh --list
scripts/test.sh --layer unit
scripts/test.sh --layer graphics
scripts/test.sh --layer rom
scripts/test.sh --layer acceptance
scripts/test.sh --filter map_renderer
scripts/test.sh --rom-source /path/to/rom.nds
```

The default command runs every available layer. Without a ready dump it runs
unit, component, and graphics tests, then emits a loud warning with ROM and
acceptance skip counts, remediation, and strict-mode instructions. This is a
successful optional skip only when all executed tests pass.

### Derived-cache preparation

Before the ROM-gated layers, `test.sh` runs `love romdump/ --build-cache`, which
follows three paths:

```text
unchanged producer:
    fingerprint + build-state check only
    (no ROM open, no compiler runs)

producer/contract/dump change:
    rebuild once, then publish the build identity

missing/damaged generated artifacts:
    repair path (rebuild only what is missing)
```

Normal ROM/acceptance test startup therefore never decodes the ROM merely to
prove cache freshness: an identity match plus a cheap availability audit
short-circuits before any ROM access. The shell treats a successful
preparation as authoritative and exports `G4RECOMP_DERIVED_CACHE_READY=1`;
a failed build makes the ROM-gated layers fail loudly rather than run against
an unverified cache.

`--layer rom`, `--layer acceptance`, and `G4RECOMP_REQUIRE_ROM_TESTS=1
scripts/test.sh` require a ready dump and fail nonzero if one is unavailable.
`--rom-source` imports and builds into an isolated temporary save root, so it
does not alter the ordinary cache or saves. `scripts/integration.sh` is a thin
documented delegate for that source-ROM command, not a second test runner.

## Writing tests

Use explicit suite metadata for new cross-layer tests and declare capabilities.
Call `context:skip(reason)` for an optional unavailable capability; returning
normally is always a pass. Keep unit and component contracts narrow. ROM suites
assert ready-dump facts; acceptance scenarios boot the real `FieldRuntime` via
the shared harness, drive semantic input, use real derived data and isolated
saves, fake only true host boundaries, and never draw. Use the `tdd` skill for
behavior changes and `acceptance-testing` before new user-visible flows.

## Troubleshooting

The default command sets `SDL_VIDEODRIVER=offscreen` and
`LIBGL_ALWAYS_SOFTWARE=1`. If graphics setup fails, install a current LÖVE 11.5
host with Mesa EGL/OpenGL software drivers; do not disable the graphics layer.
For a missing dump, prepare one with `scripts/buildcache.sh /path/to/rom.nds` or
run an isolated source test with `--rom-source`. Use `--list` to inspect
discovery and metadata, and `--filter` to narrow a failure.
