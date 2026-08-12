# Code Agent Guidance

This file provides guidance to Coding Agents when working with code in this repository.

## General Guidelines

- Be brief.
- Strongly bias towards simplicity.
- Strongly bias towards asking for clarification.
- Less code is better code. Net line count is a diagnostic, not an acceptance criterion:
  necessary correctness or safety code may make a change net-positive.
- Annotate public APIs and non-obvious table/data shapes, and anywhere an annotation
  materially improves LuaLS inference or states an invariant. Do not annotate trivial
  private locals merely because their lines were touched. `scripts/lint.sh` stays clean.
- Be concrete.
- Look for opportunities for refactoring or trimming code at the end of each task.
- Flat is better than nested.
- Look for root causes.
- Descriptive names.
- Make liberal use of assertions to enforce assumptions and invariants.
- Aggressively remove dead code, no "just in case" compatibility.
- Prefer pure functions.
- Thoroughly remove debug/trace code after each task.
- Assume unexpected changes are from the human.

## Architecture

- The repo is a small monorepo: top-level `game/` and `romdump/` are runnable apps (each its own LÖVE root); `libs/rom`, `libs/assets`, and `libs/engine` are the shared capabilities they build on. See `docs/architecture.md`.
- Cutting across that, work in three conceptual layers: interface, domain, and infrastructure.
- Domain contains all the game logic and should be testable independently of LÖVE. `libs/rom` and `libs/assets` are overwhelmingly domain and must not `require` love.
- Interface and infrastructure can depend on LÖVE, but should be kept as thin as possible.
- Modability comes through explicit mod-facing asset contracts and deliberately designated public APIs — not through interfaces, callbacks, forwarding layers, compatibility shims, or extension hooks added for hypothetical future mods. Public/mod-facing does not mean stable or frozen: stability is an explicit project decision, and until it is declared the surface stays minimal and incompatible cleanup is allowed.
- Derived data crosses three roles (see docs/architecture.md "Digestion, assets, and the game"): romdump digests raw ROM bytes, libs/assets owns the modder-facing asset contracts (text + metadata shapes), and the game operates only on the asset level — no raw-ROM decoding, no decomp-derived reference imports in libs/engine or game/src.


## Ownership and failure safety

- Every acquired resource has exactly one owner. Before acquiring, name how it is released
  on every later failure path.
- A multi-step constructor or loader must clean up what it already acquired when a later
  step fails.
- Replacing owned state disposes the previous state exactly once.
- Reentrancy/busy protection lives inside the stateful subsystem, not only in its callers.
- `push`, mount, subscribe, acquire, open, and creating an Image/Mesh/Canvas are ownership
  changes and need matching cleanup. No generic RAII helper framework.

## Persistence and publication

- Persistent user state (saves) must not share a deletion root with rebuildable/generated
  cache state.
- Never destroy the last known-good artifact before its replacement is fully built and
  validated.
- Transactional replacement is: **stage, validate, publish.** Writing the completion marker
  last proves completeness; it is not by itself transactional replacement.
- Filesystem failures propagate. A wrapper must never report success after an underlying
  write/remove/rename/create failed.
- Do not build a generic transaction framework without several concrete users.

## Schemas and errors

- Project-owned current schemas are strict. A missing required array/table is an error, not
  `{}`; an unknown enum/mode value is an error, not a plausible default.
- Generated artifacts get no backward-compatibility handling unless explicitly requested.
- Validate finite/integer/range constraints wherever a value becomes an ID, index, offset,
  tick, size, or binary field.
- Catch only errors the caller can intentionally recover from. Never recover from a whole
  error family or code prefix when some members mean corruption or a programming fault.
- Use `assert` for programming invariants; use structured `Errors` for malformed
  external/generated data and expected diagnosable runtime failures. Raise internally, and
  convert to `nil, err` only at an explicitly documented public error boundary.

## Shared state and caching

- A cache key includes every property that affects the cached object's immutable runtime
  configuration.
- Never cache by source path/bytes alone and then mutate the shared result differently per
  consumer.
- Builders, sorters, and queue builders must not attach temporary bookkeeping fields to
  caller-owned objects; keep that state local.

## Testing

- TDD: tests first for behavior changes.
- Stateful, cached, resource-owning, or asynchronous code needs at least one failure or
  multi-step sequence test, not only a happy path.
- Test behavioral ownership boundaries, not helper internals.
- Test modules are discovered recursively from the roots in `tests/run.lua`; do
  not add manual module registration.
- New cross-layer suites declare layer metadata (`metadata.layer`) and required
  `capabilities`. An explicit skip uses `context:skip(reason)`, never a normal
  return.
- Use the `tdd` skill for behavior changes. Use `acceptance-testing` before
  work that changes a user-visible flow, production composition, persistence,
  transitions, scripts, or ROM-derived behavior.
- Running the entire test suite takes a while; Run unit tests frequently, be deliberate about the other layers.
- Test economy:
  - Tests are code and runtime cost. Minimize both while preserving meaningful behavioral coverage.
  - Before adding a test, find the existing owner of the behavior. Prefer extending or
    strengthening that test over adding another.
  - A new test must protect a materially distinct failure mode, behavioral contract, or
    composition boundary. A different assertion over substantially the same setup is not
    sufficient reason for another test.
  - Prefer the cheapest layer that can prove the behavior. Edge cases, validation, state
    transitions, and failure branches belong in unit/component tests unless production
    composition itself is the contract.
  - Expensive setup should be amortized. When several assertions require the same
    production boot, ROM decode, compilation, fixture construction, or long simulated flow,
    prefer one scenario that performs the flow once and asserts all related postconditions.
  - Do not repeat an expensive user journey merely to give each postcondition its own test
    name.
  - Parameter matrices are suspect by default. Test multiple versions, resolutions, input
    modalities, or configurations only when those dimensions can materially change the
    behavior under test.
  - When adding coverage to an already-expensive layer, look for obsolete, overlapping, or
    mergeable coverage in that layer first.
  - Treat suite runtime regressions as design regressions. If a change materially increases
    an expensive layer's runtime, simplify the tests or explain why the additional cost buys
    unique coverage.
  - When a high-level test finds a bug whose cause can be isolated below that layer, put the
    regression test at the lower layer. Do not automatically add another high-level
    regression scenario.
  - For acceptance tests specifically, every production runtime boot is expensive. Minimize
    the number of boots, not merely the number of test functions.
- Adversarial prompts, to consider when applicable — not a mandatory list:
  What if the Nth acquisition fails? What if an operation starts while one is already
  active? What if a valid previous artifact exists and the rebuild fails? What if multiple
  physical inputs map to one semantic action? What if a callback mutates the listener list
  during dispatch? What if two consumers share cached data but need different mutable
  configuration?

## Commands

- Prefer running scripts from the scripts directory instead of ad-hoc commands.
- If there isn't a script for a common task, bias towards creating one.
- When authoring scripts, assume a UNIX-like environment.
- Write temporary files to `.agents/tmp/`
- Look for ROM files (.nds, .zip) in `tmp/` inside the workspace and dumps are often available in `.cache/love/g4recomp/{heartgold,soulsilver}`

When calling skills or any commands, prefer a direct syntax (avoiding e.g. variable substitution)
to avoid shell injection or permission issues.

## Commits

- Use *Scoped Commits*: `<scope>: <description>`
- Do not add `Co-Authored-By` trailers or any AI attribution. The human is solely responsible for all commits.

## Code Conventions

- **Layout:** library code lives under `libs/<lib>/src/` (`rom`, `assets`, `engine`); pure domain modules (`rom`, `assets`) must not `require` love. App code lives under `game/src/` and `romdump/src/`. Require by full repo-relative path: `require("libs.rom.src.BinaryReader")`.
- **Module shape:** each file returns one table. Instance types set `M.__index = M` and construct with `setmetatable({...}, M)`. 2-space indent, LF, final newline.
- **Header comment:** open each module with a short paragraph stating its role. Where it implements an external binary format, name the authoritative source (a GBATEK section, a `pret/pokeheartgold` file, or a `docs/` page) rather than an internal document.
- **Zero-based everywhere:** offsets, `fileId`, `memberId`, overlay tables. Iterate zero-based maps with `for id = 0, count - 1`, never `ipairs`. Never expose a generic `id`; use `narcId` / `fileId` / `memberId`.
- **Binary access:** go through `BinaryReader` (bounds-checked, zero-based, little-endian by arithmetic). No `bit`/Lua 5.3 ops needed for 8/16/32-bit values.
- **Errors vs assert:** malformed input / user faults raise `Errors.raise(CODE, message, context)` with a `SCREAMING_SNAKE_CASE` module-prefixed code (`NDS_*`, `OVERLAY_*`, `READ_*`). Programming invariants use plain `assert`. Public `open`/`parse` entry points wrap a private `_parse` in `pcall` and return `nil, err` when `Errors.is(result)`, else re-raise.
- **Tests:** unit tests live beside their library in `libs/<lib>/tests/*_test.lua` (app tests under `<app>/tests/`); each returns a table of `name -> function`, or the explicit suite shape (`metadata`/`beforeAll`/`afterAll`/`tests`). Discovery is recursive over the roots declared in `tests/run.lua` — there is no module registry, so a new `*_test.lua`/`*_tests.lua` file runs as soon as it exists. Use `tests/support/Assert`; reuse the local `throwsCode(code, fn)` helper pattern to assert a raised `Errors` object with a given code. Put binary fixture generators in `tests/support/`. Run with `scripts/test.sh`.
