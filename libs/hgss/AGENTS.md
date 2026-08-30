# libs/hgss Agent Guidance

Read root `AGENTS.md` first. `libs/hgss` owns recreated HeartGold/SoulSilver runtime
mechanisms and presents HGSS-facing seams to the application layer.

## Domain organization

Keep reviewer-facing mechanisms in these domain subpackages:

- `field` — field simulation, world state, maps, actors, and field services.
- `script` — HGSS value/reference semantics and field-shaped script adapters.
- `audio` — HGSS audio policy composed over the NDS sound mechanisms.
- `presentation` — field scene, camera, queue, and presentation composition.
- `ui` — reusable HGSS runtime UI mechanisms.
- `save` — HGSS save semantics.

HGSS may consume `libs/nds`, `libs/script`, `libs/assets`, and foundation libraries when
those mechanisms are part of a concrete runtime responsibility. It must not import
`romdump` or own application policy.

## Application boundary

Launcher state, LÖVE app composition, story flow, new-game sequencing, and Professor Oak
intro policy remain in `game`. Do not move those policies into HGSS merely because they
invoke a reusable HGSS mechanism.
