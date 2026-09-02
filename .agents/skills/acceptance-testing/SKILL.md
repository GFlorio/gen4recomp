---
name: acceptance-testing
description: Use when a deliverable changes user-visible behavior, production composition, full runtime flows, ROM-derived behavior, persistence, transitions, scripts/dialogue, or acceptance criteria in a spec — authors production-composed acceptance scenarios before implementation.
---

# Acceptance Testing

Acceptance tests prove a user-visible flow through the production composition path. They
are contract tests: authored before implementation, red for the intended reason until the
behavior lands.

## When acceptance applies

1. **Read the relevant deliverable and the existing acceptance matrix** in the spec and
   implementation notes (scenario IDs, owners, per-version requirements).
2. **Identify the public/user-observable flow and the production entrypoint.**
3. **Select acceptance only when the behavior crosses meaningful production boundaries.**
   Otherwise record a narrow exemption in the notes and rely on TDD at the correct lower
   layer. Do not create an acceptance test for a docs-only or skill-only change merely to
   satisfy a ritual.

Prefer the smallest set of production-composed scenarios that proves every material observable
outcome. Combine related postconditions from one natural user journey instead of duplicating expensive setup.

## Scenario contract

4. **Add or update a scenario before production implementation.** The scenario stays red
   until the implementation lands; never weaken it to make the branch green.
5. **Use real production composition and the real ROM-derived cache.** Boot the production
   non-rendering runtime through the shared acceptance harness
   (`tests/acceptance/support/`). Do not assemble `FieldSession`, `FieldScripts`,
   `FieldActorManager`, or transition internals by hand, and do not call digesters or
   compilers directly.
6. **Stop before GPU rendering.** The harness installs a render trap: no shader, canvas,
   image, mesh, quad, or draw call may be attempted by the acceptance path.
7. **Fake only true host boundaries** — audio output, screen fades, camera shake, event
   publication, wall clock, save-root location — with deterministic recording adapters.
   Never fake maps, scripts, actors, messages, collision, transitions, or saves.
8. **Drive semantic input and wait on semantic state** (`step`, `advanceUntil`, `move`,
   `pressAction`, `advanceDialogue`, `waitForTransition`). Fixed tick counts only when
   tick count is the behavior under test; never blind sleeps.
9. **Verify the scenario fails for the intended missing behavior** before implementation
   starts. Red must name the missing behavior, not a require path, syntax error, or
   missing capability. Run the acceptance layer with its capabilities required, so a
   missing dump or cold cache fails loudly instead of skipping. A scenario that only
   skipped was never observed red: say so in the notes and treat the deliverable as
   unverified rather than reporting a contract that no run has exercised.
10. **Freeze the behavioral contract after the intended red is observed.** Implementation may
    refactor test plumbing, but it must not weaken or materially change the scenario's setup,
    action, observable boundary, expected result, required capabilities, or version coverage to
    make the branch green. A semantic change requires an approved contract correction/deviation;
    the implementation agent cannot authorize it.
11. **Return** scenario IDs, the production boundary exercised, data/capabilities
    required, the red result, and cleanup behavior.

## Layer boundaries

Acceptance is not a synonym for other layers:

- **ROM conformance** — a ready user-owned dump through parsers, digesters, compilers,
  and corpus-wide validation. No user-visible flow, no composition.
- **Graphics smoke** — real offscreen LÖVE shaders, canvases, meshes, and images. No
  gameplay flow; acceptance stops before drawing.
- **Acceptance** — a user-visible flow through production composition, stopping
  immediately before GPU rendering.

## Real-data rules

- Never copy ROM text, payloads, or derived commercial assets into the repository.
- Assert semantic map names, message/resource IDs, actor IDs, and user-visible state
  transitions — not copied ROM text or giant byte/snapshot goldens.
- Run every scenario for each ready game version the runner selects, unless the scenario
  metadata says two versions are required.
- Keep the user's raw dump and normal save files untouched; use isolated save roots.

## Exemption path

For a non-behavioral deliverable, append a precise exemption to the implementation notes:
deliverable, why no user-visible boundary is crossed, and the lower-layer test owner (if
any). Change no production code.

## Red flags

| Thought | Reality |
|---|---|
| "It uses real ROM bytes, so it is acceptance" | Parsers/digesters against a dump is ROM conformance. Acceptance crosses a user-visible boundary through production composition. |
| "I'll build the session in the test" | Hand-assembled sessions test reconstruction, not composition. Boot the runtime. |
| "The shader compiled, that is the acceptance pass" | That is graphics smoke. Acceptance stops before any draw call. |
| "I'll wait 60 ticks for the dialogue" | Wait on controller/semantic state with bounded diagnostics. |
| "The scenario is inconvenient, I'll assert less" | A valid contract changes only with evidence and an approved contract correction/deviation, never quietly weakened. |
| "No dump here, the suite skipped and stayed green" | A skip is not the red observation. Require the capability, or record the deliverable unverified. |
