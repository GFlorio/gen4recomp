---
name: spec-based-development
description: Use when the human points at a spec file containing a list of deliverables and wants it implemented — drives implement/review/commit per deliverable through subagents.
---

# Spec-Based Development

You are the **orchestrator**. You do not write implementation code. You read the spec,
maintain the implementation notes, dispatch one subagent per step, and commit.

Every subagent starts with empty context and gets everything it needs from two files: the
spec and the notes.

## Setup

1. **Read the spec in full.** Extract the ordered list of deliverables. If the spec has no
   discernible deliverable list, stop and ask the human which unit to iterate over.
2. **Create the implementation notes file** at `.agents/tmp/<spec-basename>-notes.md`.
   It is temporary and uncommitted, like the spec.
3. **Confirm the deliverable list with the human** before dispatching anything. A wrong
   decomposition wastes the whole run.

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

## Per-deliverable loop

For each deliverable, in spec order:

**1. Implement.** Dispatch a `general-purpose` subagent. Its prompt has these five parts,
in order:

1. The absolute paths to the spec file and the notes file, and:
   `Read both in full before starting.`
2. `Implement deliverable N: <name>, and only that deliverable.`
3. `Follow CLAUDE.md. Use TDD: tests first. Run scripts/test.sh until green.`
4. `Append anything later deliverables need to the Messages section of the notes file.
   Do not edit the spec. Do not commit.`
5. The return shape: `Return: files touched, what you built, deviations from the spec and
   why, the test status, and the ownership/failure cases you introduced or changed with the
   tests covering them (say so explicitly if there are none).`

Those five parts and nothing else — no restatement of the spec's contents, no design you
have in mind, no summary of prior deliverables. The subagent reads both files itself.

**2. Review.** Dispatch the `change-review` skill
(`.agents/skills/change-review/SKILL.md`) per its Dispatch section, passing the spec and
notes paths as the optional fifth part. It reviews and fixes the uncommitted diff.

**3. Verify.** Run `scripts/test.sh` and `scripts/lint.sh` yourself. Green before commit,
always. Red means dispatch a fresh subagent to fix it — you still don't write the code.

**4. Commit.** One commit per deliverable, scoped subject line, single line, no body, no AI
attribution: `<scope>: <description>`. The message describes the change on its own terms —
no spec references, no deliverable numbers, no "per the plan". Specs are discarded; commits
are permanent.

**5. Tick the box** in the notes file and move on.

## Finish

1. Dispatch the `branch-review` skill (`.agents/skills/branch-review/SKILL.md`) per its
   Dispatch section, passing the spec and notes paths.
2. Verify tests and lint yourself, then commit any fixes it made.
3. **Report to the human:** deliverables completed, commits made, deviations from the spec,
   findings left open for a behavior decision, and the final test/lint status.

## Rules

- You orchestrate; subagents implement. If you catch yourself editing a source file, stop
  and dispatch instead.
- One deliverable per subagent, one commit per deliverable. Never batch.
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
| "I'll skip review, the subagent's code looked fine" | You can't see the code — you saw a summary. Review runs. |
| "Tests are failing but the change is obviously right" | Never commit red. |
| "I'll mention the spec in the commit message" | The spec gets discarded. The commit outlives it. |
| "The subagent should tell me its notes and I'll write them" | It writes to the notes file. Relayed context degrades. |
