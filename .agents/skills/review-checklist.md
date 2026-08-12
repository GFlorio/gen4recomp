# Review Checklist

Shared criteria for `change-review` and `branch-review`. Outside the Tests section, every
item is a *cut* lens: the default answer is "remove it", and keeping code needs a reason.

## Structure

- **Premature abstraction.** One caller is strong evidence against an abstraction, not
  proof: a single-caller boundary may stay when it carries a concrete responsibility —
  resource lifetime, layer separation, a real mod-facing API, or a domain concept grounded
  in source material. Otherwise inline it. An interface with a single implementation is not
  an interface.
- **Indirection layers.** A function that only forwards to another function, a module
  that only re-exports, a table that only wraps one value — cut them.
- **Layer violations.** `libs/rom` and `libs/assets` must not `require` love. No raw-ROM
  decoding or decomp-derived reference data in `libs/engine` or `game/src`.
- **Misplaced code.** Domain logic sitting in an interface/infrastructure module.
- **Code lacks intent.** A function that does not have a clear, single responsibility; a module that
  does not have a clear, single purpose; a class that does not have a clear, single role.

## Branches and control flow

- **Superfluous / just-in-case branches.** For every corner-case branch, state explicitly:
  can it be cut, and what breaks if it is? If nothing reachable breaks, cut it.
- **Nil/error fallbacks that hide bugs.** Prefer `assert` or `Errors.raise` over a silent
  default. Raise internally; `nil, err` only at a documented public error boundary.
- **Unjustified recovery.** A `pcall` that swallows a whole error family or code prefix, a
  missing required field defaulted to `{}`, an unknown enum mapped to a plausible value.
- **Nesting.** Flat is better than nested. Early-return instead of `if ... else` pyramids.
- **Missing assertions.** Invariants the code relies on but never checks.

## Names and literals

- **Magic literals.** Any number or string with meaning behind it wants a named constant —
  especially error codes and any string that must match in 2+ places.
- **Weak names.** `data`, `tmp`, `result`, `handle`, `id`. Never a bare `id`: use
  `narcId` / `fileId` / `memberId`.
- **Zero-based discipline.** Zero-based maps iterate `for i = 0, count - 1`, never `ipairs`.
- **Type annotations.** Public APIs and non-obvious data shapes are annotated; trivial
  private locals are not annotated just because they were touched.
- **Semantic claims as proof obligations.** *immutable*, *transactional*, *atomic*,
  *idempotent*, *terminal*, *bounded*, *exactly-once*, *restores state* — for each, name the
  mechanism that enforces it and, where practical, require a test of the failure case.
  A claim with no mechanism is a finding.

## Correctness

- **Subtle bugs.** Off-by-one, zero- vs one-based mixups, endianness, sign, aliasing of
  shared tables, stale cached state, iteration order assumptions.
- **Ownership and lifecycle.** Unclear owner, partial acquisition never cleaned up on a
  later failure, replaced state disposed twice or never, reentrancy guarded only in callers.
- **Publication and data integrity.** The last known-good artifact destroyed before its
  replacement validated; persistent user state sharing a deletion root with generated cache
  state; a filesystem wrapper reporting success after a failed underlying operation;
  marker-last completeness described as transactional replacement.
- **Shared mutation.** A cache key missing a property that changes the cached object's
  runtime configuration; shared cached data mutated per consumer; bookkeeping fields
  attached to caller-owned objects.
- **Root causes.** A fix that special-cases a symptom is a finding, not a fix.

## Tests

- **Coverage gaps.** New behavior with no test; error paths with no `throwsCode` test.
- **Missing failure sequences.** Stateful, cached, resource-owning, or asynchronous code
  with only a happy-path test.
- **Fragile tests.** Asserting on exact formatted strings, whole-table equality where one
  field matters, hardcoded offsets that duplicate the implementation, ordering assumptions
  on unordered data, real-ROM dependence in unit tests.
- **Tests that restate the implementation** instead of pinning behavior.
- **Discovery.** Test modules are discovered recursively under the roots declared in
  `tests/run.lua`; a suite outside those roots never runs. There is no registry, and
  ROM-dependent suites declare the capability they need instead of living behind a second
  command.

## Residue

- **Debug/trace code.** Leftover prints, commented-out blocks, temporary flags.
- **Spec mentions.** Specs are temporary and get discarded — no references to them in code,
  comments, docstrings, or commit messages. Same for "Gate N"-style plan phase labels.
- **Dead code.** Unused locals, unreachable arms, "just in case" compatibility shims,
  exports nobody requires.
- **Stale comments.** Comments describing what the code used to do.
