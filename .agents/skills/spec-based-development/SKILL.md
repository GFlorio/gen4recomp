---
name: spec-based-development
description: Use when the human points at a spec file containing a list of deliverables and wants it implemented — drives acceptance, implementation, review, and dependency-safe integration through subagents, using isolated worktrees for independent deliverables.
---

# Spec-Based Development

You are the **orchestrator**. You do not write implementation code. You read the spec,
maintain the implementation notes, dispatch subagents, and integrate their commits.

Every subagent starts with empty context and gets everything it needs from the spec, the
notes, and its explicitly named worktree.

## Setup

1. **Read the spec in full.** Extract the ordered list of deliverables. If the spec has no
   discernible deliverable list, stop and ask the human which unit to iterate over.
2. **Create the implementation notes file** at `.agents/tmp/<spec-basename>-notes.md`.
   It is temporary and uncommitted, like the spec.
3. **Confirm the deliverable list with the human** before dispatching anything. A wrong
   decomposition wastes the whole run.
4. **Build a dependency graph.** Treat the spec's listed order as the default dependency
   order, not an implementation queue. Mark each deliverable blocked by named prerequisites
   or safe to run independently. Explain any reordering to the human.
5. **Create isolated worktrees for independent deliverables.** Give each concurrently active
   deliverable its own branch and worktree from the same verified base commit. Keep its
   acceptance, implementation, review, verification, and commit in that worktree. Never let
   concurrent agents edit the primary worktree or a shared branch.

Parallelism is an optimization, not a reason to weaken contracts. Do not parallelize work
that shares an unfinished public interface, production file, generated artifact, or
acceptance fixture. When uncertain, serialize.

### Notes file format

```markdown
# Implementation notes — <spec basename>

## Deliverables
- [ ] 1. <name>
- [ ] 2. <name>

## Messages
Notes from completed work that later deliverables need. Append only; never rewrite history.

### From deliverable 1
- <fact a later deliverable would otherwise rediscover or contradict>
```

The Messages section is the only channel between subagents. Anything a later deliverable
must know — an interface that got named differently than the spec says, a constant's home
module, a spec assumption that turned out wrong — lives there or is lost.

Track acceptance state per deliverable: scenario IDs, the red signal observed before
implementation, and the green status after. A deliverable box ticks only when its
acceptance scenarios and implementation are committed together.

For parallel worktrees, keep a private notes copy per deliverable. After integrating its
commit, append the completed handoff facts to the primary notes file. The primary notes are
the cross-deliverable channel; do not concurrently append to them from worktrees.

## Parallel execution and integration

Dispatch each currently unblocked deliverable as an independent worktree pipeline. Within a
pipeline, preserve acceptance → implementation → review → verify → commit. Pipelines may run
concurrently only when the dependency graph shows they are independent.

After a pipeline commits, inspect its diff and verification result, then integrate it into
the primary branch using a commit-preserving operation. Integrate only ready dependencies.
Dispatch a fresh integration-fix subagent for conflicts; do not edit source yourself. Re-run
full verification after every integration batch.

The primary branch's commit order may differ from the order printed in the spec. Preserve one
cohesive commit per deliverable, but choose a dependency-safe integration order. Record the
actual order and each reordering reason in the notes and final report.

## Per-deliverable loop

For each currently unblocked deliverable, in its dedicated worktree:

**0. Acceptance contract.** Dispatch a `general-purpose` subagent. Its prompt has these
five parts, in order:

1. `Read <absolute-spec-path> and <absolute-notes-path> in full. Work only in
   <absolute-worktree-path>.`
2. `Read .agents/skills/acceptance-testing/SKILL.md and follow it.`
3. `Work only on deliverable <N>: <exact deliverable text>. Create/update acceptance
   tests before implementation. Do not modify production code. Verify red for the
   intended reason. If executable acceptance is not appropriate, append a precise
   exemption to the notes and change no production code.`
4. `Append scenario IDs, files changed, required capabilities, expected red signal,
   actual red result, and facts learned to the notes. Do not commit.`
5. `Return: scenarios added/changed, production boundary exercised, red result,
   fixtures/adapters used, and any exemption.`

It may edit `tests/support` and test-only fixtures, but no production code.

**1. Implement.** Dispatch a `general-purpose` subagent. Its prompt has these parts, in
order:

1. The absolute paths to the spec file and the notes file, plus the worktree path:
   `Read both in full before starting. Work only in <absolute-worktree-path>.`
2. `Implement deliverable N: <name>, and only that deliverable.`
3. `Read .agents/skills/tdd/SKILL.md and follow it.`
4. `The acceptance tests from the prior subagent are contract tests. Make them pass
   without weakening them. Add lower-layer tests as required by TDD.`
5. `Follow CLAUDE.md. Run scripts/test.sh until green.`
6. `The spec is temporary context. Do not copy deliverable numbers, phase names, or plan
   terminology into code, tests, comments, docstrings, or commit messages.`
7. `Append anything later deliverables need to the Messages section of the notes file.
   Do not edit the spec. Do not commit.`
8. The return shape: `Return: files touched, what you built, deviations from the spec and
   why, the test status, and the ownership/failure cases you introduced or changed with the
   tests covering them (say so explicitly if there are none).`

The implementation subagent may correct an objectively invalid acceptance test only after
recording the evidence in the notes and returning the decision for review; it may not
quietly change the contract.

Those parts and nothing else — no restatement of the spec's contents, no design you have
in mind, no summary of prior deliverables. The subagent reads both files itself.

**2. Review.** Dispatch the `change-review` skill
(`.agents/skills/change-review/SKILL.md`) per its Dispatch section, passing the spec and
notes paths as the optional fifth part. It reviews and fixes the uncommitted diff.

**3. Verify.** Run `scripts/test.sh` and `scripts/lint.sh` yourself in the worktree. Green before commit,
always. Red means dispatch a fresh subagent to fix it — you still don't write the code.
Record pass/fail/skip counts by layer. A skipped layer is not a pass: if the deliverable's
contract lives in a layer that skipped for a missing capability, the deliverable is
unverified. Make the capability available and rerun, or record it unverified in the notes
and leave its box unticked.

**4. Commit.** One commit per deliverable in its worktree, scoped subject line, single line, no body, no AI
attribution: `<scope>: <description>`. Each commit contains its acceptance test and its
implementation together. The message describes the change on its own terms — no spec
references, no deliverable numbers, no "per the plan". Specs are discarded; commits are
permanent.

**5. Tick the box** in the worktree notes file and move on. After integration, transfer its
handoff facts and completion state to the primary notes file.

## Finish

1. Dispatch the `branch-review` skill (`.agents/skills/branch-review/SKILL.md`) per its
   Dispatch section, passing the spec and notes paths.
2. Verify tests and lint yourself, then commit any fixes it made.
3. **Report to the human:** deliverables completed, commits made, deviations from the spec,
   findings left open for a behavior decision, and the final test/lint status.

## Rules

- You orchestrate; subagents implement. If you catch yourself editing a source file, stop
  and dispatch instead.
- One deliverable per worktree pipeline, one cohesive commit per deliverable. Never batch.
- Never commit red. Never commit the spec or the notes file.
- Never commit a deliverable while review leaves an unresolved correctness bug, data-loss
  risk, resource-ownership/lifecycle bug, or deterministic-state bug. Dispatch a fix
  subagent. Escalate to the human only when the correct behavior is genuinely ambiguous.
- A deliverable that fails review twice is a signal the spec is wrong, not that the subagent
  needs a third try — unless the remaining issue is an objectively established
  implementation bug, which is fixed, not escalated. Otherwise stop and take it to the human.
- Report honestly. If a deliverable is incomplete or a test is failing at the end, say so
  with the output.

## Red flags

| Thought | Reality |
|---|---|
| "This deliverable is tiny, I'll just do it" | You are the orchestrator. Dispatch. |
| "I'll implement two deliverables in one subagent" | One per subagent. Batching hides which change broke what. |
| "I'll paste the spec section into the prompt" | Give the path. Paraphrase drifts; the file doesn't. |
| "I'll skip the acceptance subagent, the test can come later" | The contract is authored and red before implementation. Docs-only deliverables get an exemption, not silence. |
| "I'll implement, then backfill the acceptance scenario" | The scenario is the contract. It must exist and be red before the production edit. |
| "The acceptance test is red, close enough" | Red must name the missing behavior — a load/syntax/capability failure is a test bug. |
| "The suite is green, so the deliverable is verified" | Green with its layer skipped proves nothing. Skipped ≠ passed. |
| "I'll skip review, the subagent's code looked fine" | You can't see the code — you saw a summary. Review runs. |
| "Tests are failing but the change is obviously right" | Never commit red. |
| "I'll mention the spec in the commit message" | The spec gets discarded. The commit outlives it. |
| "The subagent should tell me its notes and I'll write them" | It writes to the notes file. Relayed context degrades. |
