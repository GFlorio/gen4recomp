# game Agent Guidance

Read root `AGENTS.md` first. `game` is the application/composition layer for gameplay and
user-visible flows.

## Composition boundary

- Normal runtime consumes generated assets and engine APIs only. Raw ROM/NDS/HGSS decoding,
  decomp-derived tables, NARC/Nitro/overlay parsing, and source packing stay out of `game/src`.
- The launcher/import UI is the sole provisioning exception allowed to call into `romdump`.
  Keep that dependency at the import boundary; do not let source concepts leak into normal
  gameplay state after provisioning.
- Game-specific content policy, scene/flow sequencing, and feature behavior belong here.
  Reusable engine mechanisms belong in `libs/engine` only when a concrete current reusable
  responsibility exists.
- Reuse the engine/assets owner instead of creating game-local decoders, caches, resource
  managers, or alternate business-rule implementations.

## User-visible behavior

- Changes to production composition, persistence, transitions, scripts, ROM-derived gameplay,
  or other user-visible flows use the `acceptance-testing` skill before implementation.
- Keep semantic input/actions at the game boundary; do not bind domain behavior to incidental
  device events when the input layer already owns normalization.
- Preserve user saves across generated-cache rebuild/removal. See
  `.agents/docs/defensive-patterns.md`.

## Public/mod-facing APIs

- A mod-facing API is deliberate product surface. Add only the operations a current gameplay
  or modding requirement needs; do not mirror internals or add forwarding hooks "for later".
- Keep game-specific APIs semantic. Source IDs/offsets/member paths are not runtime/mod API
  vocabulary unless a concrete feature establishes them as semantic identity.

## Tests

- Unit/component tests cover local game policy/state; acceptance exercises the real production
  `FieldRuntime`/composition path where wiring or user-visible sequencing is the contract.
- Do not add production optionality just because a fake omits a required engine collaborator.
