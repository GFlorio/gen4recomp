# libs/engine Agent Guidance

Read root `AGENTS.md` first. `libs/engine` owns reusable runtime mechanisms that consume
normalized g4recomp assets; it does not own ROM ingestion or game-specific policy.

## Runtime boundary

- Consume generated assets only. Do not import `romdump`, decomp-derived references, or
  NARC/Nitro/overlay parsers, and do not decode source binary packing at runtime.
- Reusable runtime mechanisms belong here; game-specific sequencing/content/policy belongs in
  `game` unless more than one current consumer establishes a real engine responsibility.
- Keep pure domain/state logic independent of LÖVE where practical even though engine
  interface/infrastructure modules may own LÖVE resources.

## Ownership and lifecycle

- Engine objects that acquire Images, Meshes, Canvases, mounts, subscriptions, or other host
  resources own explicit exactly-once disposal. Read `docs/defensive-patterns.md` for
  multi-step acquisition/replacement rules.
- Constructors produce usable objects or fail. Do not make required render/audio/runtime
  collaborators optional to satisfy tests or partial setup.
- Stateful systems own reentrancy/busy/ordering invariants internally; callers should not be
  the only protection against invalid interleavings.
- Shared caches separate immutable cached identity from per-consumer mutable state and include
  every immutable configuration property in the cache key.

## Public and mod-facing surface

- New public methods, callbacks, hooks, extension points, configuration options, and framework
  abstractions require a concrete current consumer/requirement. A planned future mod studio or
  hypothetical mod does not count by itself.
- Prefer extending the existing owner, LÖVE/native behavior, installed dependencies, or a
  small local implementation before creating another manager/framework layer.
- Do not export private helpers for tests. Test through the semantic owner or move the
  responsibility if another production module genuinely needs it.

## Tests

- Unit/component tests own pure state and lifecycle edge cases; graphics tests own actual LÖVE
  graphics behavior; acceptance owns production composition/user flow. Use the cheapest layer
  that proves the contract.
- Resource-owning/asynchronous state gets at least one material failure/sequence test. Avoid
  mocks that bypass the real owner being tested.
