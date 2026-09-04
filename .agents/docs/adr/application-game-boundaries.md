# ADR: Application and game boundaries

**Status:** Accepted
**Date:** 2026-08-31
**Scope:** Ownership of the interactive process shell, running-game lifecycle, concrete HGSS
application, and reusable HGSS mechanisms.

## Context

The interactive product has one supported concrete game, HeartGold/SoulSilver, but it still
has distinct responsibilities. Process callbacks, launcher and ROM provisioning must not be
coupled to a running game's lifecycle. The running game needs a small host for state
replacement, event forwarding, resizing, exit notification, and disposal. HGSS menu, story,
new-game, field, save, and audio policy then compose reusable HGSS mechanisms into the
playable product.

Without these boundaries, `game` becomes a catch-all application owner, `FieldSession` can be
mistaken for the product entry point, and reusable HGSS mechanisms can acquire launcher or
story policy. The existing runtime-package decision in
[runtime package boundaries](runtime-package-boundaries.md) remains the foundation for the
library side of this split.

## Decision

The shipped interactive topology has four application/runtime levels:

- `app` is the LÖVE process shell. It owns process callbacks, launcher and version selection,
  ROM file-drop provisioning, cache-readiness routing, and process exit policy. Its one direct
  `romdump` dependency is the provisioning workflow. It composes a concrete game application.
- `game` is the game-agnostic running-game host. `game.src.Game` owns state replacement,
  update/draw and input forwarding, drawable-size reconciliation, exit, and exactly-once
  disposal. Host adapters such as `LocalClock`, `RepoFs`, `WindowConfig`, and the LÖVE audio
  sink live here.
- `game/hgss` is the concrete HeartGold/SoulSilver application. `game.hgss.src.HgssGame`
  configures the generic host with Main Menu, Continue, New Game/Oak, field, save
  compatibility, and application audio.
- `libs/hgss` contains reusable HGSS mechanisms, including field simulation, scripts, audio,
  presentation, UI, and save semantics. `FieldSession` remains a field-simulation mechanism,
  not a game entry point.

The current control flow is `app.src.App` → `game.hgss.src.HgssGame` → `game.src.Game` →
concrete HGSS states and mechanisms. Provisioning flows from `app` to `romdump`, while normal
runtime data flows from the generated cache into `game/hgss` and `libs/hgss`.

The package split is an internal ownership decision, not a public or mod-facing plugin API.
There is no plugin registry, generic Gen-IV package, dynamic game discovery, cross-game save
interface, or generic provisioning protocol.

## Alternatives considered

- Keep launcher, generic lifecycle, and HGSS policy in one catch-all `game` package: rejected
  because process concerns, host lifecycle, and concrete product policy would remain coupled.
- Use `FieldSession` as the game entry point: rejected because it owns fixed-tick field
  simulation, not process, menu, story, save, or application composition.
- Put application policy in `libs/hgss`: rejected because reusable mechanisms must remain
  independent of launcher and product flow.
- Introduce a plugin registry or generic Gen-IV framework now: rejected because one concrete
  game supplies no proven common contract and the added public surface would be speculative.

## Consequences

Contributors can classify process and provisioning changes under `app`, generic host changes
under `game`, HGSS product policy under `game/hgss`, reusable HGSS behavior under `libs/hgss`,
and ROM/source production under `romdump`. Structural architecture checks enforce the
dependency direction; this ADR records why it exists rather than duplicating those checks.

The extra package boundaries add navigation and composition seams, and a concrete HGSS entry
must configure the generic host. In return, process exit and file drops stay above the game,
generic host concerns do not acquire HGSS meaning, and reusable mechanisms do not acquire
application policy. The split changes no save schema, generated-asset schema, mod-script API,
ROM/cache format, `data/` path, or runtime behavior.

## Revisit when

Revisit this decision when a second supported concrete game creates duplicated launch or
composition responsibilities and exposes a common lifecycle contract that is needed by both
games. Until that evidence exists, keep the current concrete boundary and do not add a
framework for hypothetical games.
