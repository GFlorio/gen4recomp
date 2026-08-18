---
name: spec-based-development
description: Implement a finalized implementation-spec bundle containing `SPEC.md` plus `deliverables/Dxx-*.md` files. Use when the human points at a spec bundle produced by an implementation-spec writer and wants the repository changed through dependency-safe subagent pipelines with acceptance-first implementation, isolated worktrees, review, verification, and integration. Treat the spec bundle and all orchestration notes as temporary artifacts that must never leak into permanent repository content.
---

# Spec-Based Development

Act as the **orchestrator**. Do not write implementation code. Read the shared contract, maintain
temporary orchestration state, dispatch subagents, verify results, and integrate commits.

The specification bundle is authoritative implementation context. It has this shape:

```text
SPEC.md
deliverables/
  D01-<slug>.md
  D02-<slug>.md
  ...
```

`SPEC.md` is shared context. Each deliverable pipeline reads `SPEC.md`, exactly its own deliverable
file, its temporary implementation notes, and the repository. Do not make coding agents read
unrelated deliverable files.

The entire spec bundle is temporary and will be discarded. Never copy or reference `SPEC.md`, the
bundle, deliverable IDs/numbers, requirement IDs, acceptance IDs, phase names, or planning
terminology in production code, tests, test names, comments, docstrings, documentation, changelogs,
or commit messages. Describe permanent artifacts only in terms of the behavior they implement.

## Setup

1. **Locate the bundle root.** Accept either an unpacked bundle or a ZIP containing `SPEC.md` at its
   root. If given a ZIP, extract it under `.agents/tmp/`. Keep the bundle temporary and uncommitted.
2. **Read `SPEC.md` in full.** Require the sections emitted by the writer: Goal, Global constraints,
   Non-goals, Source basis, Shared terminology, Shared architecture, Global decisions, Requirement
   coverage, Deliverables, Dependency graph, Cross-deliverable contracts, Global verification, and
   Integration constraints. If the bundle does not follow that contract, stop rather than guessing.
3. **Verify the repository baseline.** Compare the current primary-worktree `HEAD` with the full
   `Research commit` in `SPEC.md` → `Source basis`. They must match before implementation begins.
   If they differ, stop and tell the human that the spec was researched against a different revision;
   do not silently reinterpret exact file, symbol, API, or acceptance prescriptions against new code.
4. **Validate the deliverable index mechanically.** Every `Dxx` row must name an existing file. Use
   the declared `Depends on`, Dependency graph, Cross-deliverable contracts, and Integration
   constraints as the scheduling contract. Do not re-decompose the work or ask the human to reconfirm
   a finalized decomposition.
5. **Do not preload every deliverable.** `SPEC.md` is the orchestration index. Read a deliverable file
   when preparing, checking, or integrating that deliverable.
6. **Create the primary notes file** at `.agents/tmp/<bundle-name>-notes.md` and the sanitized
   deviation ledger at `.agents/tmp/<bundle-name>-deviations.md`. Both are temporary and uncommitted.

### Primary notes format

```markdown
# Implementation notes — <bundle name>

## Deliverables
- [ ] D01 — <name>
- [ ] D02 — <name>

## Acceptance state
### D01
- A-D01-01 — red: <observed intended red>; green: <pending|pass|fail|unverified>

## Messages
Append-only handoff facts that later deliverables would otherwise rediscover or contradict.

### From D01
- <actual implementation fact needed by a dependent deliverable>

## Integration
- <commit/order/verification facts>
```

The `Messages` section is the implementation-time channel between deliverable pipelines. Stable spec
IDs may appear in temporary notes, but never in committed repository artifacts.

For concurrently active worktrees, create a private notes copy for each deliverable. After a commit
is integrated, append only its completed handoff facts, acceptance state, and integration facts to the
primary notes file. Never concurrently append to the primary notes file from worktrees.

### Deviation ledger format

The deviation ledger is **not** an implementation diary and must contain no speculative reasoning,
failed approaches, agent summaries, or plausibility arguments. It records only approved amendments
to the normative specification:

```markdown
# Approved specification deviations — <bundle name>

## DEV-01 — <short description>
- Deliverable: Dxx
- Spec location: `<file>` → `<section or contract>`
- Authoritative replacement: <precise replacement contract>
- Acceptance impact: <affected acceptance behavior/IDs, or "None">
- Authority: <human decision OR objective repository fact with concrete evidence>
```

If there are no approved deviations, leave the file with the heading and `None.`

A subagent may **propose** a deviation in implementation notes, but cannot approve one. Before work
continues under a changed contract:

- require human approval if the change affects observable behavior, architecture, API semantics,
  persistence, compatibility, security, failure behavior, concurrency/ownership, acceptance criteria,
  deliverable boundaries, or cross-deliverable contracts;
- allow an orchestrator-approved correction only for an objectively false implementation fact that is
  proven by concrete repository evidence at the exact research baseline and does not change behavior
  or another locked contract;
- record the approved replacement in the deviation ledger before redispatching work;
- copy only the relevant approved replacement into that deliverable's temporary notes.

Never edit the specification files to hide a deviation.

## Dependency-safe worktrees

Dispatch every currently unblocked deliverable as an isolated worktree pipeline.

- Independent deliverables may branch from the same verified base commit and run concurrently.
- A dependent deliverable must start from the primary branch **after** all declared prerequisites it
  consumes have been integrated.
- Do not parallelize work that `SPEC.md` marks as ordered or conflicting through Integration
  constraints, unfinished cross-deliverable contracts, generated artifacts, shared mutable fixtures,
  or migrations.
- If an unexpected implementation conflict appears, serialization is safe; changing the declared
  contract or dependency relationship is a deviation and follows the deviation process above.

Within each worktree preserve:

**acceptance → implementation → review → verification → commit**

After a pipeline commits, inspect its diff and verification state, then rebase its branch onto the
current primary branch and fast-forward the primary branch. Keep history linear; do not create merge
commits. For conflicts, dispatch a fresh integration-fix subagent rather than editing source yourself.
Give that subagent `SPEC.md`, only the affected deliverable files, relevant approved deviations, the
primary notes, and the worktree path.

Re-run applicable global verification after each integration batch. Remove integrated worktrees and
delete their temporary branches.

## Per-deliverable pipeline

For `Dxx`, first read its deliverable file in full. Treat every section as contractual according to its
wording, including Dependencies and contracts, Requirements owned, Behavioral contract, Architecture
and design, Interfaces and data contracts, Required implementation, Acceptance contract, Lower-level
test requirements, Verification, Pitfalls and forbidden approaches, Handoff, Allowed implementation
discretion, and Definition of done.

### 0. Author the acceptance contract

Dispatch a `general-purpose` subagent with these parts, in order:

1. `Read <absolute-SPEC.md>, <absolute-Dxx-file>, and <absolute-worktree-notes> in full. Work only in
   <absolute-worktree>. Do not read other deliverable files.`
2. `Read .agents/skills/acceptance-testing/SKILL.md and follow it.`
3. `Implement exactly the scenarios under this deliverable's Acceptance contract before production
   implementation. Do not modify production code. Preserve each scenario's behavior, setup, observable
   boundary, expected result, test layer, capabilities, and expected pre-implementation red.`
4. `Use A-Dxx-yy IDs only in temporary notes to map scenarios to tests. Never put spec IDs, spec names,
   deliverable numbers, or planning terminology in test names, test code, fixtures, comments, or other
   committed artifacts.`
5. `Verify each scenario red for the intended missing-behavior reason. A syntax/load/capability failure
   is not the required red. If the behavior is already green, the expected red is impossible, or the
   contract appears invalid, do not invent a replacement. Record concrete evidence as a proposed
   deviation in the notes and stop.`
6. `Append scenario-to-test mapping, files changed, required capabilities, expected red, actual red,
   explicit exemptions already allowed by the spec, and facts learned to the notes. Do not commit.`
7. `Return: scenarios implemented, production boundary exercised, red result per scenario,
   fixtures/adapters/capabilities used, and any proposed deviation or exemption.`

It may edit test support and test-only fixtures when required by the acceptance contract, but no
production code.

### 1. Implement

Dispatch a fresh `general-purpose` subagent with these parts, in order:

1. `Read <absolute-SPEC.md>, <absolute-Dxx-file>, and <absolute-worktree-notes> in full before starting.
   Work only in <absolute-worktree>. Do not read other deliverable files.`
2. `Implement Dxx and only Dxx. Satisfy its owned requirements, behavioral contract, architecture,
   interfaces/data contracts, required implementation, lower-level test requirements, verification,
   pitfalls, handoff, and definition of done. Exercise discretion only where Allowed implementation
   discretion explicitly leaves a choice open.`
3. `Read .agents/skills/tdd/SKILL.md and follow it. Read and follow the repository instructions named
   in SPEC.md plus any applicable repo-local instructions.`
4. `The acceptance tests from the prior subagent are contract tests. Make them pass without weakening,
   deleting, bypassing, or changing their semantics. Add lower-layer tests required by the deliverable.`
5. `The entire specification is temporary. Never copy or reference SPEC.md, deliverable IDs/numbers,
   requirement IDs, acceptance IDs, phase names, or planning terminology in code, tests, test names,
   comments, docstrings, documentation, changelogs, or commit messages.`
6. `If a locked spec statement appears wrong or impossible, do not silently reinterpret it and do not
   alter acceptance semantics. Record the concrete conflict and evidence as a proposed deviation in the
   notes, stop that disputed part, and return it for orchestrator resolution.`
7. `Append actual handoff facts later deliverables need to Messages, plus test/verification status and
   any proposed deviation. Do not edit the spec. Do not commit.`
8. `Return: files touched, behavior built, spec-contract status, proposed deviations if any, tests and
   verification run, and ownership/lifecycle/failure cases changed with the tests covering them.`

If an approved deviation exists, redispatch with the relevant authoritative replacement already copied
into the temporary notes. The subagent must treat that replacement as overriding only the exact spec
location named in the deviation; all other spec clauses remain in force.

### 2. Review the deliverable diff

Dispatch `.agents/skills/change-review/SKILL.md` according to its Dispatch section. Give it:

- the absolute `SPEC.md` path;
- the absolute path to this deliverable file;
- this worktree's implementation-notes path;
- any approved deviation affecting this deliverable;
- the worktree path.

It reviews and fixes the uncommitted diff. It may use implementation notes in this per-deliverable
review because this review is part of the implementation pipeline. It must not silently waive or alter
a spec contract. Any newly discovered contract conflict returns to the deviation process before commit.

### 3. Verify

Run every command under the deliverable's `## Verification` section in the worktree. Also run any
`SPEC.md` → `## Global verification` command that is applicable at this point and safe before full
integration.

Record pass/fail/skip by command and by acceptance scenario in the worktree notes. A skipped test layer
or missing capability is **not** a pass. If a required contract cannot execute, make the capability
available and rerun, or leave the deliverable unverified and uncommitted.

All acceptance scenarios owned by the deliverable, required lower-level tests, and required
verification commands must be green before commit.

### 4. Commit

Create one cohesive commit for the deliverable containing its acceptance tests and implementation
together. Use a scoped, one-line subject with no body and no AI attribution:

```text
<scope>: <description>
```

Describe the resulting code change on its own terms. Do not mention the spec, `Dxx`, `Rxx`, `A-Dxx-yy`,
planning phases, or "per the plan". Never commit the spec bundle, implementation notes, or deviation
ledger.

### 5. Complete and integrate

Tick `Dxx` in the worktree notes only after its acceptance contract, lower-level tests, verification,
implementation, review, and commit are complete. Integrate dependency-safely, then copy its actual
handoff facts, acceptance state, and integration result into the primary notes.

Do not rewrite the spec's `## Handoff` section. If the actual handoff contradicts a locked contract,
that is a deviation and must already be approved and recorded.

## Final branch review

After all deliverables are integrated:

1. Cross-check `SPEC.md` → `Requirement coverage`: every `Rxx` owner must be complete and every listed
   `A-Dxx-yy` must have a green acceptance result in the primary notes. Resolve any gap before review.
2. Run every command in `SPEC.md` → `Global verification` on the integrated primary branch. Required
   commands must pass; skipped required capabilities remain unverified.
3. Dispatch `.agents/skills/branch-review/SKILL.md` according to its Dispatch section. Give the branch
   reviewer the absolute `SPEC.md` path and the absolute deviation-ledger path. Instruct it to read
   `SPEC.md` and **every deliverable file listed in its Deliverables table** as the normative contract.
4. **Never give branch review the implementation notes, worktree notes, agent summaries, failed
   approaches, or a paraphrase of their reasoning.** Do not copy notes into its prompt. The final review
   must independently judge the repository against the specification rather than inherit plausible but
   potentially wrong implementation reasoning.
5. The deviation ledger is the only implementation-time context the branch reviewer receives. Tell it
   to treat each recorded deviation as an authoritative amendment to only the exact spec location it
   names, while independently verifying the resulting code. An empty ledger means there were no
   approved deviations.
6. Verify all Global verification commands again after any fixes the branch review makes, then commit
   review fixes without spec/planning references. If review exposes a genuine spec-contract ambiguity,
   use the same deviation process; do not let the reviewer decide product behavior implicitly.

## Finish

Report to the human:

- deliverables completed and commits made;
- approved deviations from the original spec contract;
- any findings left open because a behavior decision was required;
- acceptance coverage status;
- final Global verification status.

Then discard the temporary spec extraction, implementation notes, worktree notes, and deviation ledger
when the surrounding workflow permits. None belongs in repository history.

## Rules

- Orchestrate; subagents implement. If you catch yourself editing source, stop and dispatch.
- Treat finalized `SPEC.md` decomposition, requirement ownership, dependencies, and cross-deliverable
  contracts as authoritative. Do not re-plan them casually.
- One deliverable per worktree pipeline and one cohesive deliverable commit. Never batch deliverables.
- Coding agents read `SPEC.md` plus their own deliverable file, not the whole bundle.
- Never commit red, skipped-required, or otherwise unverified work.
- Never commit the spec bundle, notes, or deviation ledger.
- Never propagate temporary IDs or planning vocabulary into permanent repository artifacts.
- Never change acceptance semantics without an approved deviation.
- Never commit while review leaves an unresolved correctness bug, data-loss risk,
  resource-ownership/lifecycle bug, deterministic-state bug, or violated cross-deliverable contract.
- Never expose implementation notes to final branch review. Approved deviations are the sole exception
  and must be conveyed only through the sanitized deviation ledger.
- A repeated review failure that points to a genuinely wrong spec contract is not solved by trying a
  third implementation. Resolve the contract through the deviation process.
- Report incompleteness and verification failures exactly; do not turn skipped or blocked work green.

## Red flags

| Thought | Reality |
|---|---|
| "I'll confirm or improve the deliverable decomposition first" | The finalized bundle already locks ownership, dependencies, and contracts. Execute it. |
| "I'll read every deliverable so I understand the whole plan" | `SPEC.md` is shared context. Load only the active deliverable unless integration work truly requires more. |
| "HEAD is close enough to the research commit" | Exact implementation prescriptions were researched at a pinned SHA. Baseline drift invalidates that assumption. |
| "I'll paste the deliverable into the subagent prompt" | Give paths. Paraphrase and duplication drift; the files are the contract. |
| "I'll put A-D01-01 in the test name for traceability" | Spec IDs are temporary and must not enter committed artifacts. Keep the mapping in notes. |
| "The acceptance test is red, close enough" | Red must be the specific missing-behavior signal required by the scenario. |
| "The acceptance test is inconvenient, so I'll adjust it" | The scenario is contractual. Propose a deviation instead of weakening it. |
| "The suite is green, so the deliverable is verified" | Required skipped layers or capabilities prove nothing. Skipped is not passed. |
| "The branch reviewer should see the notes so it understands our choices" | Notes can anchor the reviewer to plausible-but-wrong reasoning. Give it the spec plus sanitized approved deviations only. |
| "I'll mention D02 or the spec in the commit for context" | The spec is discarded. Permanent history must describe the implementation itself. |
