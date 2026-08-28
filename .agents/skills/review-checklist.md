# Review Checklist

Shared review-only lenses for `change-review` and `branch-review`. Repository architecture,
subsystem rules, and test mechanics live in the applicable `AGENTS.md` and `docs/`; read
those first. This file should not become a second source of repository facts.

## Premise and intent

- **Prove the premise.** Establish the behavior the change claims to fix or add. Trace the
  actual execution/data path and identify the owner where behavior changes.
- **Check intentional absence.** Before restoring an apparently missing branch, field,
  fallback, or dependency, inspect tests, docs/ADRs, and relevant history when omission may
  be load-bearing.
- **Fix the bug class.** Inspect sibling callers/entry paths. A local symptom patch is a
  finding when the invariant belongs to a shared owner.
- **Separate evidence from rationale.** Plausible author reasoning is not evidence. Prefer
  current callers, contracts, runtime paths, tests, source material, and accepted decisions.

## Simplification and replacement ladder

For every substantial new module, abstraction, dependency, helper layer, option, hook,
callback, compatibility path, or public/mod-facing API, ask in order:

1. Can it be deleted because the requested behavior does not need it?
2. Can the existing owner absorb the behavior?
3. Does Lua, LÖVE, the platform, or the standard environment already provide it?
4. Does an already-installed dependency provide it?
5. Can the implementation remain small and local rather than shared/public?
6. Would a maintained new dependency materially reduce total owned code/tests/maintenance?
7. If permanent shared surface remains, what concrete current consumer and invariant earn it?

Prefer findings that name the smaller replacement, not merely "this feels over-engineered".
One caller is strong evidence against a reusable abstraction unless the boundary itself owns
resource lifetime, layer separation, a current public contract, or a source-grounded concept.

Also look for:

- wrappers that only rename or forward;
- interfaces with one implementation and no independent contract;
- configuration with one legitimate current value;
- duplicated normalization/control flow that can happen once at the owner;
- state, caches, enums, conversions, and compatibility shims with no current requirement;
- comments explaining complexity that can instead be deleted.

## Control flow and explicit intent

- **Just-in-case branches.** For each corner-case/fallback path, name the reachable current
  input/caller/contract that needs it. If none exists, cut it.
- **Unjustified recovery.** Silent defaults, broad `pcall` recovery, swallowed error families,
  and plausible unknown-enum mappings are suspect. Impossible states should usually fail
  loudly or be prevented by construction.
- **Fake-driven production behavior.** A branch needed only because a test fake omits a
  required collaborator weakens production; fix the fake.
- **Nesting and indirection.** Flatten control flow and delete names/temporaries/layers that
  make the invariant harder to see.
- **Semantic claims are proof obligations.** For words such as immutable, transactional,
  atomic, idempotent, terminal, bounded, exactly-once, or restores state, identify the
  mechanism that makes the claim true and test material failure cases where practical.
- **Names and literals.** Flag ambiguous names, generic IDs, protocol/error strings that can
  diverge, and literals whose semantic name prevents mistakes. Do not mechanically extract
  every literal.

## Correctness and lifecycle

Read `docs/defensive-patterns.md` when the diff owns resources, publishes replacement state,
uses caches/shared state, or handles partial failure. Look for:

- off-by-one, zero/one-based, sign, endianness, uniqueness, ordering, and aliasing errors;
- unclear or competing ownership;
- partial acquisition leaks, double disposal, stale replacement state, and caller-only busy
  guards;
- half-valid objects whose methods branch around missing required collaborators;
- publication that destroys last-known-good state too early or confuses stage ownership;
- cache keys missing configuration, per-consumer mutation of shared cached data, or temporary
  bookkeeping attached to caller-owned objects;
- duplicate business rules with slightly different semantics;
- transformed/swallowed failures that lose the distinction between expected failure,
  corruption, and programmer error.

Defensive code is not automatically good. Prefer making invalid states impossible or loud
when the branch cannot be justified by a current contract.

## Tests

Read `tests/AGENTS.md` and `docs/testing.md`.

- New/changed behavior needs the smallest credible behavioral test at the owning layer.
- Stateful/resource-owning/asynchronous behavior needs material failure/sequence coverage.
- Prefer invariants/relationships over snapshots of expected-to-change catalogs, counts,
  generated lists, or incidental private representation.
- Reject source-text/change-detector tests that police implementation shape instead of
  behavior or an intentionally enforced architecture boundary.
- Real composition is required when wiring/composition itself is the contract; a hand-built
  mock graph cannot prove production discovery, persistence, ROM-derived loading, or host
  integration.
- Look for weak assertions, tests passing for the wrong reason, duplicate journeys,
  implementation-reproducing mocks, and expensive setup that indicates excessive coupling.
- A test does not justify production complexity when the tested behavior itself has no
  current requirement.

## Residue

- Debug/trace output, commented-out blocks, temporary flags, TODO scaffolding.
- Temporary spec/requirement/deliverable/acceptance/deviation/phase vocabulary in permanent
  artifacts or commit messages.
- Dead exports, locals, branches, compatibility aliases, and stale comments.
- Documentation or comments that preserve an implementation-history narrative instead of a
  current contract or durable ADR-worthy decision.
