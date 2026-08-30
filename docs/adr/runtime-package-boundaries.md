# ADR: Runtime package boundaries

**Status:** Accepted
**Date:** 2026-08-30
**Scope:** Ownership and dependency direction for reusable runtime mechanisms, source
producers, generated assets, and application composition.

## Context

The runtime has accumulated reusable Nintendo DS behavior, mod-script machinery, and
recreated HeartGold/SoulSilver mechanisms under one engine namespace. That broad owner
makes dependency direction and reviewer ownership unclear. The source producer also has
responsibility for supported-ROM identity and HGSS-specific compilation, while the
application owns launcher and story policy. These responsibilities need explicit seams
before physical module moves begin.

The durable ownership question is: does behavior exist because Nintendo DS/Nitro works
that way, because HGSS works that way, because the mod platform works that way, or because
g4recomp stores or composes it that way? The answer determines its owner.

## Decision

The target top-level runtime packages are `libs/nds`, `libs/script`, and `libs/hgss`,
alongside the existing foundation and asset packages.

- `libs/nds` owns reusable Nintendo DS, Nitro, and NNS mechanisms. Its semantic levels are
  explicit: `rom`, `nitro/g3d`, `gx`, `nitro/sound`, and the host-specific `love` backend.
  It depends downward on foundations only; it does not know project asset schemas or HGSS.
- `libs/script` owns the project mod DSL/compiler/runtime/scheduler/registry substrate.
  `gen4.script` is the only supported mod-facing script surface. HGSS meanings enter the
  generic machinery through collaborators rather than being embedded in script core.
- `libs/hgss` owns recreated HGSS mechanisms, organized by `field`, `script`, `audio`,
  `presentation`, `ui`, and `save`. It may compose NDS, script, and asset mechanisms but
  does not own launcher, story, or new-game policy.
- `libs/assets` owns g4recomp-defined generated and mod-facing serialization, validation,
  paths, and schemas.
- `romdump` owns supported-ROM identity, HGSS source interpretation, lowering, and derived
  asset compilation. It may consume lower reusable packages but never HGSS runtime code.
- `game` owns launcher/application composition, story and new-game flow, intro policy, and
  the user-facing product states. It reaches Nintendo mechanisms through HGSS-facing APIs
  and does not import `libs.nds` directly. The launcher may use the existing narrow
  `romdump` provisioning boundary.

The dependency direction is foundations → NDS, assets/script → HGSS, HGSS beside romdump,
and game at the application top. The existing `libs/engine` tree remains only as a
transitional physical location until its consumers are migrated; it is not a target owner
and receives no compatibility forwarding modules.

Mixed current seams are split by meaning rather than assigned to a miscellaneous package:
`NdsRom` separates generic cartridge parsing from supported-ROM identity and cache policy;
`DsMaterial` separates Nintendo register semantics from HGSS field policy;
`AudioBank.selectVoice` follows its Nintendo algorithm while asset serialization stays in
`libs/assets`; `RuntimeValues` separates generic script evaluation from HGSS references;
and `MapRenderer` separates NDS raster execution from HGSS field presentation.

## Alternatives considered

- Retain `libs/engine` as the permanent broad runtime owner: rejected because it hides
  semantic ownership and keeps unrelated dependency directions coupled.
- Put all low-level behavior in a single `libs/nds` miscellaneous bucket: rejected because
  mod-platform and HGSS semantics are not Nintendo platform semantics, and the resulting
  bucket would recreate the same working-set problem.
- Add compatibility forwarding modules from the old namespace: rejected because internal
  package paths are not a persisted or supported contract, and aliases would prolong the
  ambiguous ownership model.

## Consequences

Contributors can classify a module by the reason its behavior exists, and later moves have
an explicit dependency DAG. `libs/nds` stays independent of project-specific schemas,
`libs/script` stays independent of HGSS meaning, and `game` remains independent of Nintendo
implementation details. Physical relocation is still required; this decision does not
change runtime behavior, persistence schemas, generated asset schemas, or resource
lifecycle contracts.

The transitional engine tree makes the repository temporarily describe both a physical
legacy location and the target semantic owners. Architecture checks therefore include
future package roots without enforcing the final engine deletion until all consumers have
moved.

## Revisit when

Revisit if the completed migration reveals a fourth coherent semantic package that cannot
fit this dependency graph without an inversion. Resolve that responsibility explicitly
before the final engine deletion; do not introduce a catch-all package.
