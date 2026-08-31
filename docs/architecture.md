# Architecture

g4recomp separates source knowledge, generated contracts, reusable runtime
mechanisms, and product composition. The boundaries keep ROM-specific facts
out of the runtime and keep user state independent from rebuildable assets.

## Dependency direction

```text
romdump source knowledge
        ↓
generated libs/assets contracts
        ↓
reusable libs/engine runtime
        ↓
game product composition
```

`romdump` owns NDS, HGSS, Nitro, overlay, archive, and decomp-derived meaning.
It normalizes that knowledge into project-owned generated assets in
`libs/assets`. The reusable runtime consumes those assets and does not decode
the source formats. `game` owns user-visible sequencing and product policy.
The launcher/import boundary may call into `romdump` to provision a cache; the
normal runtime path does not.

## Ownership criteria

- Source-specific parsing, selection, provenance, and compilation belong in
  `romdump`, even when the implementation is pure.
- Generated paths, schemas, validation, and source-independent encoders belong
  in `libs/assets` when producers and consumers share that contract.
- Reusable runtime mechanisms belong in `libs/engine` when a concrete current
  consumer needs them without source-specific knowledge.
- Game flow, content policy, and user-visible composition belong in `game`.
- Generic binary, storage, error, and mathematical primitives belong in their
  focused libraries rather than in an application layer.

Prefer the existing owner and the smallest local mechanism that satisfies the
current requirement. A public API, hook, configuration option, or shared
abstraction needs a concrete consumer; hypothetical mod or feature needs are
not ownership evidence.

## Data lifecycle

Raw ROM data is private provisioning input. Import validates it before publishing
a ready dump, and generated assets are disposable and rebuildable. Once
provisioning is complete, runtime code reads the derived cache and does not need
the ROM. Persistent user saves live in a separate namespace from generated
cache data so rebuilding or removing assets cannot remove user progress.

Replacement flows stage and validate new state before publishing it, preserving
the last known-good state when acquisition or publication fails. Exact resource
ownership and malformed-data behavior remain contracts of the owning code and
tests.

## Public and mod-facing surface

Expose semantic generated data and operations that a current consumer can use.
Keep source IDs, offsets, archive members, packing details, and other
provenance out of runtime or mod-facing vocabulary unless a concrete product
feature gives them semantic meaning. Do not add speculative hooks or preserve
development artifacts as compatibility contracts.

## Starting points

For a focused code-reading path, start with:

- `game/main.lua` and `romdump/main.lua` for application entrypoints;
- `libs/assets/src/DerivedAssetContract.lua` for the generated contract owner;
- `romdump/src/` for source ingestion and producers;
- `libs/engine/src/` for reusable runtime mechanisms;
- `tests/`, `tests/AGENTS.md`, and the nearest subtree `AGENTS.md` for executable
  contracts and engineering rules.

These pointers are navigation aids, not a catalog. Current behavior belongs in
the owning implementation and tests.
