# libs/ui Agent Guidance

This package owns the narrow game-independent widget primitives:

- `Button` — generic layered geometry, cut-corner painter, and hit-test.
- `TextButton` and `ImageButton` — composition over `Button`.

## Ownership

- No first-party production dependencies. Game and asset state stays in consumers.
- Widgets receive an injected LÖVE-like graphics object (`setColor`, `rectangle`, `polygon`, plus transform/line stack for TextButton) and caller-owned color/content adapters. They never read global `love`, own GPU resources, or require `game`, `libs/hgss`, `libs/assets`, or `romdump`.
- Resolved geometry is a caller-owned snapshot; widgets retain no state, resources, or semantic selection/navigation between calls.

## Boundaries

- Generic button behavior belongs here; HGSS-specific dialogue, field-menu, font, or source-aware UI stays in `libs/hgss/src/ui`.
- Every new shared abstraction needs a concrete current consumer in the repository. A single caller is evidence to keep code local.

## Verification

- `scripts/test.sh --filter "libs.ui.tests"` proves the family.
- `tests/architecture/module_boundaries_test.lua` enforces the leaf package and allowed consumers.
