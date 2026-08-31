# app Agent Guidance

Read root `AGENTS.md` first. `app` is the interactive LÖVE process shell and the composition
boundary above a concrete game application.

## Process and provisioning ownership

- `app/main.lua` and `app/conf.lua` own process callbacks and the interactive LÖVE root.
  `app/src/App.lua` owns launcher state, version selection, ROM file-drop import, cache
  readiness routing, and the current process-exit policy.
- `app` may call `romdump` only for the current ROM provisioning/source workflow. Keep ROM
  identity and importer concepts at that boundary; do not leak them into the running-game
  host or reusable runtime mechanisms.
- The shell launches a concrete game application such as `game.hgss.src.HgssGame` and owns
  the returned running-game lifecycle. An updater, when implemented, belongs here; no
  updater or generic provisioning API is defined by this package.
- Do not import `libs/nds` or `libs/hgss` directly from `app`. HGSS application policy belongs
  in `game/hgss`, and game-agnostic host lifecycle belongs in `game`.

## Boundaries and tests

- File drops remain an app concern, including while a running game is active. `Game` has no
  file-drop or ROM-provisioning API.
- Preserve the current quit behavior: a concrete game requests exit through its `Game` host,
  and the app maps that request to process termination.
- App tests cover launcher/options and process-shell composition. Structural dependency
  ownership is enforced by `tests/architecture/module_boundaries_test.lua`; do not add
  documentation wording tests or a game registry to enforce it.
