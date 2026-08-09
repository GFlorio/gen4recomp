# Review Checklist

Shared criteria for `change-review` and `branch-review`. Outside the Tests section, every
item is a *cut* lens: the default answer is "remove it", and keeping code needs a reason.

## Structure

- **Premature abstraction.** One caller? Inline it. An interface with a single
  implementation is not an interface.
- **Indirection layers.** A function that only forwards to another function, a module
  that only re-exports, a table that only wraps one value — cut them.
- **Layer violations.** `libs/rom` and `libs/assets` must not `require` love. No raw-ROM
  decoding or decomp-derived reference data in `libs/engine` or `game/src`.
- **Misplaced code.** Domain logic sitting in an interface/infrastructure module.

## Branches and control flow

- **Superfluous / just-in-case branches.** For every corner-case branch, state explicitly:
  can it be cut, and what breaks if it is? If nothing reachable breaks, cut it.
- **Nil/error fallbacks that hide bugs.** Prefer `assert` or `Errors.raise` over a silent
  default. Throw instead of returning error codes or nil.
- **Nesting.** Flat is better than nested. Early-return instead of `if ... else` pyramids.
- **Missing assertions.** Invariants the code relies on but never checks.

## Names and literals

- **Magic literals.** Any number or string with meaning behind it wants a named constant —
  especially error codes and any string that must match in 2+ places.
- **Weak names.** `data`, `tmp`, `result`, `handle`, `id`. Never a bare `id`: use
  `narcId` / `fileId` / `memberId`.
- **Zero-based discipline.** Zero-based maps iterate `for i = 0, count - 1`, never `ipairs`.
- **Type annotations.** Every function and table touched by the change should be annotated.

## Correctness

- **Subtle bugs.** Off-by-one, zero- vs one-based mixups, endianness, sign, aliasing of
  shared tables, stale cached state, iteration order assumptions.
- **Root causes.** A fix that special-cases a symptom is a finding, not a fix.

## Tests

- **Coverage gaps.** New behavior with no test; error paths with no `throwsCode` test.
- **Fragile tests.** Asserting on exact formatted strings, whole-table equality where one
  field matters, hardcoded offsets that duplicate the implementation, ordering assumptions
  on unordered data, real-ROM dependence in unit tests.
- **Tests that restate the implementation** instead of pinning behavior.
- **Registration.** New test modules must be in the `MODULES` list of the runner that owns
  them — `tests/run.lua`, or `tests/private/run.lua` for ROM-dependent tests.

## Residue

- **Debug/trace code.** Leftover prints, commented-out blocks, temporary flags.
- **Spec mentions.** Specs are temporary and get discarded — no references to them in code,
  comments, docstrings, or commit messages. Same for "Gate N"-style plan phase labels.
- **Dead code.** Unused locals, unreachable arms, "just in case" compatibility shims,
  exports nobody requires.
- **Stale comments.** Comments describing what the code used to do.
