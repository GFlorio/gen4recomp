# libs/hgss Agent Guidance

Read root `AGENTS.md` first. `libs/hgss` owns recreated HeartGold/SoulSilver runtime
mechanisms and presents HGSS-facing seams to the application layer.

## Domain organization

Keep reviewer-facing mechanisms in these domain subpackages:

- `field` — field simulation, world state, maps, actors, and field services.
- `script` — HGSS value/reference semantics and field-shaped script adapters.
- `audio` — HGSS audio policy composed over the NDS sound mechanisms.
- `presentation` — field scene, camera, queue, and presentation composition.
- `ui` — reusable HGSS runtime UI mechanisms; game-independent button primitives belong in `libs/ui`.
- `save` — HGSS save semantics.

HGSS may consume `libs/nds`, `libs/script`, `libs/assets`, and foundation libraries when
those mechanisms are part of a concrete runtime responsibility. It must not import
`romdump` or own application policy.

## Application boundary

Launcher state, LÖVE process composition, version selection, ROM provisioning, and process
exit policy belong to `app`.
Story flow, Main Menu, new-game sequencing, Professor Oak intro policy, field application
composition, save compatibility, application audio, and developer preview belong to the
concrete `game/hgss` package. Do not move those policies into this library merely because
they invoke a reusable HGSS mechanism.
The generic running-game lifecycle and host adapters belong to `game`; `FieldSession` is a
field-simulation mechanism, not a game entry point.
