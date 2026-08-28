---
name: spec-based-development
description: Implement finalized design-heavy implementation-spec bundles in gen4recomp through dependency-safe isolated subagent pipelines. Use when a human provides SPEC.md plus deliverables/Dxx-*.md and wants the repository changed while preserving pinned-baseline design contracts, exact repository reuse/compatibility prescriptions, acceptance-first development, TDD, fresh-context design and deletion reviews, exact per-deliverable commit messages, controlled deviations, and final branch verification without leaking temporary spec context into permanent artifacts.
---

# Spec-Based Development

Act as the orchestration layer for a finalized implementation specification. Do not write production code yourself. Validate the contract, create isolated worktrees, dispatch fresh subagents, arbitrate deviations, run verification, preserve the prescribed commit history, and advance the protected target only after independent final review.

The coding agents execute the design. They do not redesign the feature merely because another implementation looks plausible.

The entire specification bundle and all orchestration state are temporary. Never propagate `SPEC.md`, deliverable/requirement/acceptance IDs, deviation IDs, planning terminology, implementation notes, or spec rationale into production code, tests, test names, comments, docstrings, documentation, changelogs, or commit messages.

## Contract semantics

Interpret the finalized bundle exactly as follows:

- **Locked**: all normative text is locked by default, including compatibility, reuse, architecture, lifecycle, interfaces, implementation footprint, novelty budget, implementation recipe, acceptance, verification, handoff, and commit contracts. Changing a locked contract requires an approved deviation.
- **Preferred**: only text explicitly marked `**Preferred:**`. An implementation may choose a mechanically equivalent local alternative only when every locked behavior, architecture boundary, lifecycle rule, public surface, compatibility rule, and acceptance result remains identical. Record the alternative and concrete equivalence evidence in temporary notes so review can judge it. If equivalence is arguable rather than objective, treat the choice as locked and propose a deviation.
- **Discretionary**: only choices explicitly listed under `## Allowed implementation discretion`. Keep them behaviorally and architecturally immaterial.

A weaker agent must not infer additional discretion from words such as “implementation detail”, “for example”, or “follow conventions”.

## Workflow

1. Prepare and validate the bundle against the current design-heavy contract.
2. Capture and protect the target branch/head; create a dedicated integration branch/worktree from the exact research commit.
3. Schedule all currently unblocked deliverables from the declared DAG.
4. For each deliverable run: acceptance authoring -> implementation -> fresh design-contract review -> deletion/cleanup review -> verification -> exact commit -> integration.
5. Re-run applicable global verification after each integration batch.
6. After all deliverables integrate, audit requirement coverage and exact commit history, run global verification, perform a fresh integrated design review, then run the normal branch review.
7. Fold any valid final-review fixes into their owning deliverable commits, rerun verification/review, and only then fast-forward the protected target.
8. Report completion, deviations, verification, and any unresolved blockers; remove temporary state when safe.

## 1. Prepare the bundle

Accept either a ZIP or an unpacked directory with this root shape:

```text
SPEC.md
deliverables/
  D01-<slug>.md
  D02-<slug>.md
```

Extract ZIPs under `.agents/tmp/`; never commit the bundle.

Read `SPEC.md` in full. Require: Goal, Global constraints, Non-goals, Source basis, Shared terminology, Shared architecture, Global decisions, Requirement coverage, Deliverables, Dependency graph, Cross-deliverable contracts, Global verification, and Integration constraints.

For every deliverable require the current design-heavy sections, including:

- Current-state evidence and Compatibility contract;
- Repository reuse contract with Must reuse / Must preserve / May extend or refactor / Must not reimplement / New abstractions justified;
- Behavioral contract;
- Architecture and design, including responsibility boundaries and extension/public surface;
- Implementation footprint and Novelty budget;
- Interfaces and data contracts;
- Required implementation and file-by-file Implementation recipe;
- Acceptance contract, Lower-level test requirements, Verification, and Review hotspots;
- Pitfalls and forbidden approaches, Handoff, Commit, Allowed implementation discretion, and Definition of done.

Stop rather than guessing when a required section is missing, an exact file/symbol prescription is unresolved, the dependency graph is invalid, a commit message is templated instead of literal, or the bundle contains unresolved TODO/TBD placeholders.

### Baseline and protected target

Require a clean primary worktree. Capture:

- current named target branch;
- current target `HEAD`;
- full `Research commit` from `SPEC.md`.

The target `HEAD` must equal the research commit before implementation starts. Do not reinterpret a spec against a nearby revision. Never stash, reset, discard, or absorb unrelated human changes.

Create a dedicated local integration branch/worktree, for example `agent/<bundle-slug>`, from the research commit. All implementation, integration, final review, fixups, and history rewriting happen there. Do not advance the protected target until the end. Never push or open a PR unless the human separately asks.

## 2. Temporary orchestration state

Keep temporary state under ignored paths such as:

```text
.agents/tmp/<bundle-slug>/
  bundle/
  notes.md
  deviations.md
  worktree-notes/

.worktrees/spec-<slug>-Dxx/
```

Initialize `notes.md` with deliverable, acceptance, integration, and handoff state. Use it as an append-only implementation-time channel; do not turn it into a reasoning diary.

Use this deviation ledger:

```markdown
# Approved specification deviations — <bundle>

## DEV-01 — <short description>
- Deliverable: Dxx
- Spec location: `<file>` -> `<section / exact contract>`
- Authoritative replacement: <precise replacement contract>
- Acceptance impact: None | <exact affected scenarios>
- Evidence: <repository fact, test/live evidence, or human decision>
- Authority: orchestrator-objective-evidence | human
```

If there are none, write `None.`.

A subagent may propose but never approve a deviation. The orchestrator may approve only a narrow objective correction proven by repository evidence at the research baseline when externally observable behavior, acceptance semantics, architecture, ownership, lifecycle, API/persistence/security/failure contracts, dependency edges, and public surface remain unchanged. All other material changes require human approval.

Never edit the spec to conceal an approved deviation.

## 3. Dependency-safe worktrees

For each currently unblocked deliverable:

- create a dedicated branch/worktree from the current integration branch;
- independent deliverables may run concurrently from the same integrated prerequisite state;
- a consumer starts only after every provider it depends on is integrated;
- serialize when `Integration constraints`, generated artifacts, shared mutable fixtures, migrations, or overlapping unfinished interfaces make parallel work unsafe.

After a deliverable is verified and committed, rebase it onto the current integration branch and fast-forward the integration branch. Do not create merge commits. If a conflict requires semantic edits, dispatch a fresh integration-fix subagent with only the affected contract files and approved deviations.

Remove integrated worktrees and temporary branches.

## 4. Subagent context boundary

`SPEC.md` is shared contract context. A deliverable pipeline receives only:

- absolute path to `SPEC.md`;
- absolute path to exactly its own deliverable file;
- absolute path to its private worktree notes;
- absolute path to the deviation ledger and IDs of deviations applicable to it, or `None`;
- its worktree path;
- repository-local instructions/skills discovered normally.

Do not preload unrelated deliverables. Do not paste or paraphrase the spec into prompts; pass paths.

Final integrated reviewers receive the spec bundle and approved deviations but **never** implementation/worktree notes, author summaries, failed approaches, or design rationalizations produced during implementation.

## 5. Per-deliverable pipeline

Read the active deliverable in full before dispatching. In particular, explicitly inspect its Compatibility contract, Repository reuse contract, Architecture and design, Implementation footprint, Novelty budget, Implementation recipe, Review hotspots, and Commit contract before any production implementation begins.

### 5.1 Author acceptance first

Dispatch a fresh `general-purpose` subagent:

1. Read `SPEC.md`, the active deliverable, and worktree notes; work only in the worktree and do not read other deliverables.
2. Read `.agents/skills/acceptance-testing/SKILL.md` and follow it.
3. Author exactly the deliverable's acceptance scenarios before production implementation. Preserve setup, observable boundary, expected result, layer, fixtures/capabilities, and expected pre-implementation red.
4. Keep spec IDs only in temporary notes; never place them in committed test names/code/fixtures/comments.
5. Observe the intended missing-behavior red. Syntax/load/capability/unrelated failures are not valid red. If a scenario is already green or its expected red is objectively impossible, record evidence and propose a deviation; do not manufacture failure.
6. Modify only tests/test support/fixtures permitted by the contract; do not modify production code or commit.
7. Record scenario-to-test mapping, red/pass/blocked state, capabilities, and concrete facts in worktree notes.

### 5.2 Implement the prescribed design

Dispatch a fresh `general-purpose` subagent:

1. Read `SPEC.md`, the active deliverable, worktree notes, applicable deviations, repository instructions, and `.agents/skills/tdd/SKILL.md`.
2. Implement only this deliverable. Treat all unmarked normative text as Locked, explicitly marked `**Preferred:**` text as Preferred, and only `Allowed implementation discretion` as Discretionary.
3. Follow the Repository reuse contract literally: reuse exact named mechanisms; preserve named contracts; do not reimplement prohibited concerns; introduce only abstractions justified by `New abstractions justified` and the Novelty budget.
4. Follow the Architecture and design contracts for responsibility, public/private surface, state ownership, lifecycle, control flow, ordering, and extension points.
5. Follow the file-by-file Implementation recipe. Do not substitute another architecture merely because it could satisfy acceptance tests.
6. Treat Implementation footprint as an overbuild guard. If materially more production files, layers, helpers, or shared abstractions appear necessary, stop before adding them, re-search repository reuse, and propose a design deviation when the expansion remains necessary.
7. Make pre-authored acceptance tests pass without weakening them; add the required lower-level tests.
8. If deviating from a Preferred prescription, record the exact alternative and objective equivalence evidence in notes. Do not create a deviation when equivalence is clear; otherwise stop and propose one.
9. Never copy temporary spec/planning vocabulary into permanent artifacts.
10. If a Locked contract is false or impossible, stop that disputed part and record concrete evidence as a proposed deviation. Do not silently reinterpret it.
11. Record only actual handoff facts, verification state, Preferred alternatives, and proposed deviations. Do not commit.

### 5.3 Fresh design-contract review

Before generic cleanup, dispatch a fresh `general-purpose` reviewer with **no implementation summary or author reasoning**. Give only `SPEC.md`, the active deliverable, applicable approved deviations, and the worktree path. Do not give implementation notes.

The reviewer must read the full diff and independently audit:

- Compatibility: every `preserve` behavior remains preserved and every intentional change is deliberate.
- Reuse: every Must reuse / Must not reimplement clause is obeyed; parallel implementations are deleted or replaced with repository mechanisms.
- Novelty: inventory every new production module/class/helper/shared abstraction and compare it to `New abstractions justified` plus the Novelty budget. Unbudgeted shared abstraction is presumptively removed; if truly necessary it is a design deviation.
- Architecture: responsibility boundaries, public/private surface, state ownership, lifecycle, ordering, and extension points match the locked design.
- Footprint: unexpected production machinery triggers a reuse/design re-check rather than normalization of the larger design.
- Recipe: changed production files and material symbols follow the prescribed seams, helpers, sequence, cleanup, and forbidden alternatives.
- Preferred choices: any departure is objectively mechanically equivalent; otherwise treat it as a contract conflict.
- Review hotspots: explicitly inspect every hotspot and its named repository analogue.
- Acceptance/test ownership: tests prove contracts rather than preserve accidental implementation complexity.

Apply a deletion/reuse bias. Fix violations directly when the locked contract determines the correction. Return only unresolved decisions that genuinely require a deviation.

### 5.4 Deletion and repository-quality review

After design conformance, dispatch `.agents/skills/change-review/SKILL.md` using its fresh-context Dispatch protocol. Supply the worktree and the active contract paths without an implementation summary. This pass is responsible for the repository-wide simplification, naming, branch, residue, lint, and test checklist.

A cleanup must not override a locked design contract. If the generic review wants to simplify something the spec intentionally locks, that is a proposed deviation rather than permission to rewrite the architecture.

### 5.5 Verify

Run every command under the deliverable's `## Verification`, plus any `SPEC.md` Global verification command applicable and safe at this stage.

Record each acceptance scenario and verification command as pass/fail/blocked. Required skipped/unavailable capabilities are not green.

Also check the deliverable's `## Commit` Gate before committing.

Do not commit while acceptance/lower-level tests fail, required verification is blocked, a design-contract review finding is unresolved, or change-review leaves a correctness/lifecycle/determinism/contract finding unresolved.

### 5.6 Commit exactly as prescribed

Read the deliverable's `## Commit` contract.

- `Required: yes`: tracked changes must exist and must fit Scope/Exclusions. Commit once using the exact literal `Message` **verbatim**, with no body, trailers, AI attribution, or rewriting.
- `Required: no`: require no tracked deliverable changes and create no commit.
- `Required: conditional`: if tracked changes are necessary, use the exact literal Message verbatim; if all gates pass with no tracked changes, create no empty commit.

Never synthesize `<scope>: <description>`. The spec writer already researched repository history and chose the subject.

Record the resulting commit SHA and exact subject in temporary notes, then integrate dependency-safely.

## 6. Cross-deliverable contracts

Provider contracts in `SPEC.md` are Locked shared interfaces. Consumers must use the exact provided symbol/schema/lifecycle/stable guarantees and must respect explicit non-guarantees.

A consumer may not extend or reinterpret a provider contract because its implementation would be easier. If the provided contract is insufficient, stop and propose a deviation before changing either deliverable.

Implementation-time handoff messages may report concrete realized facts, but they may not silently broaden a cross-deliverable contract.

## 7. Final coverage, history, and integrated design review

After every deliverable is integrated on the dedicated integration branch:

1. Cross-check `Requirement coverage`: every requirement owner completed and every mapped acceptance scenario is green.
2. Audit every deliverable Commit contract against branch history. Each required/changed deliverable has exactly the prescribed subject; no forbidden body/trailer/planning vocabulary exists; no unexpected implementation commit bypasses a deliverable contract.
3. Run every `SPEC.md` Global verification command.
4. Dispatch a fresh integrated design reviewer with `SPEC.md`, **every deliverable listed in the Deliverables table**, the deviation ledger, and the integration worktree. Explicitly forbid implementation notes and author summaries.
5. The reviewer independently repeats the compatibility/reuse/novelty/architecture/footprint/recipe/hotspot audit across the complete integrated diff, with special attention to cross-deliverable duplication, contract reinterpretation, public-surface growth, and abstractions that became unnecessary after integration.
6. Fix only findings whose correct resolution is established by the locked contract. Material contract changes use the deviation process.
7. Run `.agents/skills/branch-review/SKILL.md` as a final deletion-biased repository review. Give it the specification contract and approved deviations, never implementation notes.
8. Re-run all affected and global verification after review fixes.

### Preserve exact deliverable history after final-review fixes

Final-review fixes must not create an arbitrary extra “review fixes” commit that defeats exact per-deliverable commit contracts.

Classify each fix by owning deliverable. For each affected deliverable, create a temporary `fixup!` commit targeting that deliverable's exact commit, then autosquash on the integration branch. Split fixes when they belong to different deliverables. If a fix changes cross-deliverable ownership or cannot be assigned without changing the finalized decomposition, treat it as a deviation.

After autosquash, re-run the exact commit-history audit, global verification, and final integrated review. The final branch should retain the exact subjects prescribed by the spec.

## 8. Advance the protected target

Immediately before delivery, verify the protected primary worktree is still clean, still on the captured target branch, and still at the captured target head. If it moved, stop for explicit reconciliation; do not reset, overwrite, or force-update it.

Only after final coverage, history audit, verification, and reviews are green may the target branch be fast-forwarded to the reviewed integration branch. Never force-update the target.

## 9. Finish

Report concisely:

- deliverables completed and their exact commit subjects/SHAs, including legitimate zero-commit deliverables;
- approved deviations and authority;
- Preferred alternatives actually used;
- acceptance coverage and blocked capabilities;
- final Global verification state;
- unresolved human decisions, if any.

Remove prepared bundle extraction, worktree notes, integrated worktrees, and other temporary state when safe. Preserve nothing from the discarded spec in repository history.

## Hard rules

- Orchestrate; subagents implement and review.
- Execute the finalized design; do not casually re-plan it.
- Exact research baseline or stop.
- Locked is the default. Preferred requires objective mechanical equivalence. Discretionary exists only where explicitly granted.
- Reuse named repository mechanisms; unbudgeted shared abstractions require re-search and usually a deviation.
- Acceptance green does not excuse violating architecture/reuse/lifecycle contracts.
- Never weaken acceptance to make an implementation pass.
- Never invent or rewrite deliverable commit messages.
- Never create empty commits for no-change/conditional deliverables.
- Never commit the spec bundle, notes, deviations, or temporary IDs/planning vocabulary.
- Never expose implementation notes or author reasoning to final integrated reviewers.
- Never turn blocked/skipped required verification green.
- Never push or create a PR unless separately requested.

## Red flags

| Thought | Reality |
|---|---|
| “The tests pass, so this alternative architecture is fine.” | Acceptance proves behavior, not conformance to a locked design/reuse contract. |
| “I can make this cleaner with a new generic helper.” | New shared abstractions must be justified and budgeted in the finalized spec. |
| “The prescribed helper is awkward, so I will copy its logic.” | `Must reuse` and `Must not reimplement` are design contracts, not suggestions. |
| “Preferred means optional.” | Only mechanically equivalent alternatives are allowed without a deviation. |
| “I will pick a better commit subject.” | The exact message is already part of the deliverable contract. |
| “I will add a final cleanup commit.” | Fold final fixes into their owning deliverable commits and preserve prescribed subjects. |
| “The final reviewer should see our notes so it understands why.” | Independent review must not inherit implementation rationalizations. |
| “HEAD is close enough to the research commit.” | Exact file/symbol recipes were researched at one pinned revision; drift invalidates them. |
