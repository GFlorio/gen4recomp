# Test Agent Guidance

Read root `AGENTS.md` and `docs/testing.md`. This file contains standing test-design orders;
`docs/testing.md` remains the source of truth for runner/layer/capability mechanics.

## What tests should protect

- Test externally observable behavior, relationships between values, ownership/lifecycle
  contracts, and architecture boundaries that are intentionally normative.
- Do not write change-detector tests that fail because expected-to-change catalogs, counts,
  generated lists, version literals, or equivalent data were updated normally.
- Do not read production source text to prove a deleted symbol/string stays absent. If a
  deletion preserves no behavioral or intentional architecture invariant, it needs no
  permanent regression test.
- Structural tests are appropriate when structure itself is the contract, such as forbidden
  dependency directions. Prefer mechanical/static checks with low false-positive rates.

## Test at the owning boundary

- Use the cheapest layer that can prove the behavior. Validation, state transitions, and
  failure branches usually belong below acceptance when production composition is not the
  contract.
- Use real composition when discovery/wiring, persistence, ROM-derived loading, graphics host
  integration, or a production flow is what could fail. A hand-assembled mock graph cannot
  prove the real entry path.
- When a high-level scenario finds a bug that can be isolated at a lower owner, put the
  regression at that lower layer unless the high-level composition also failed independently.
- Required production collaborators remain required. Improve a fake or inject failure at a
  real boundary instead of adding test-only production fallbacks.

## Failure and lifecycle evidence

Stateful, cached, resource-owning, publication, or asynchronous behavior needs at least one
material failure or multi-step sequence test when the contract depends on sequencing. Useful
questions include:

- What happens when acquisition N fails after earlier acquisitions succeeded?
- Does replacing state dispose the old state exactly once?
- Can a stale/late operation publish after ownership moved?
- Does failure preserve the last known-good artifact/state?
- Can independent consumers mutate shared cached state inconsistently?

Do not multiply cases mechanically; choose the sequence that actually distinguishes correct
ownership from the plausible bug.

## Test economy

- Tests are permanent code and runtime cost. Before adding one, find the existing test owner
  and strengthen it when that expresses the same contract more clearly.
- A new test earns existence by protecting a materially distinct behavior/failure/composition
  contract, not by producing another test name for the same setup.
- Amortize expensive boot, ROM decode, compilation, fixture construction, and long simulated
  flows. Prefer one scenario with related postconditions over repeating the journey.
- Parameter matrices need evidence that the varied dimension can change behavior.
- Treat material runtime growth in expensive layers as a design regression; simplify or state
  the unique coverage it buys.

## Runner and discovery

- `scripts/test.sh` is the test entry point. Use `--filter` and `--layer` for focused local
  evidence; use the full available suite at integrated/branch gates.
- Test modules are discovered recursively from roots in `tests/run.lua`; do not add a manual
  registry. A suite's layer comes from its discovery root.
- Suites declare required `capabilities`. Optional unavailable capability uses
  `context:skip(reason)`; a normal return is a pass, never a skip.
- Unit tests use synthetic data. ROM-dependent facts live in ROM/acceptance/source-E2E layers
  and use user-owned dumps without committing commercial data.
- CI does not provide the user's ROM. A green CI run does not prove a ROM/acceptance contract
  whose required capability was unavailable.
