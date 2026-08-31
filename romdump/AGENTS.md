# romdump Agent Guidance

Read root `AGENTS.md` first. This file owns rules specific to ROM ingestion, source research,
and compilation into g4recomp assets.

## Source ownership

- `romdump` owns every structure whose meaning comes from the NDS ROM, HGSS behavior, Nitro
  formats, overlays, NARCs, or decomp/reverse-engineering references. A parser being pure does
  not make it a shared runtime library.
- Keep source-member selection, physical archive/file/member IDs, overlay addresses, packed
  source flags, and ROM-specific catalogs producer-side unless a generated asset has a
  concrete runtime/mod-facing semantic need for the fact.
- `libs/codec` supplies generic binary primitives; the interpretation of Nintendo/HGSS bytes
  stays here.
- Build-only source manifests and provenance belong here. Generated/mod-facing schemas belong
  in `libs/assets` and must not need HGSS knowledge to interpret.

## Source evidence and vocabulary

- Source-format modules and source-derived tests name the authoritative external/source
  reference in their header comment: GBATEK, a pinned `pret/pokeheartgold` symbol/file and
  commit, or another authoritative primary source. Do not use a checked-in focused research
  document or temporary implementation spec as the authority.
- Distinguish verified ROM facts from inferred semantics. Use neutral names when gameplay
  meaning has not been traced yet; do not promote a guess into a durable asset field.
- Source offsets, `narcId`, `fileId`, `memberId`, overlay table indices, and similar source
  identities are zero-based. Never expose a generic `id` when the source identity kind matters.
- Validate finite/integer/range constraints before values become offsets, indices, sizes, or
  binary fields. Treat malformed source data as structured errors, not plausible defaults.

## Compilation boundary

- If an implementation change can alter generated output for the same ROM while the shared
  asset contract is unchanged, it is producer implementation and belongs under `romdump`.
- Normalize source-specific structure before publication so runtime code does not need NARC,
  Nitro, overlay, packed-bitfield, or decomp knowledge.
- Do not duplicate winner selection, schema validation, source resolution, or normalization in
  inspectors/debug tools. Inspection surfaces call the authoritative producer logic.
- Compiler implementation freshness uses the `romdump/src` producer fingerprint. Do not add a
  manual compiler version just to invalidate cache after source-code changes.
- A real generated contract change updates the authoritative `DerivedAssetContract` identity
  in `libs/assets`; do not use contract versions as source-code revision counters.

## Tests

- Pure source decoders/parsers can use synthetic unit fixtures. Keep commercial ROM bytes and
  derived commercial assets out of the repository.
- ROM/compiler/corpus facts use the ROM layer and declare the required capability. Do not make
  unit tests depend on a user-owned dump.
- When source compilation changes a user-visible runtime behavior, pair producer evidence with
  the cheapest runtime/acceptance evidence that proves the normalized asset is consumed
  correctly.
- Byte-for-byte/generated-output checks are appropriate when reproducibility is the actual
  compiler contract; do not snapshot incidental catalogs just to notice ordinary additions.
