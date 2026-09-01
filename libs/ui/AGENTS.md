# libs/ui Agent Guidance

Read root `AGENTS.md` first. `libs/ui` owns game-independent, LÖVE-independent UI
mechanisms shared by concrete current consumers.

- Keep modules pure Lua and free of LÖVE, game, HGSS, app, and source knowledge.
- Add shared modules only for a concrete cross-feature consumer; this package does not
  promise a stable mod-facing API.
- Keep feature policy, rendering, and device input in the consuming application or
  feature-specific package.
