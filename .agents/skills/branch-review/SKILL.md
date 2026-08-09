---
name: branch-review
description: Use when reviewing everything a branch adds on top of master — a thorough, methodical critical pass over a large body of unmerged work, often written by a weaker agent.
---

# Branch Review

A thorough critical review of **all unmerged changes on the current branch**. Assume the
code was written by a weaker agent: it is probably over-abstracted, over-branched, and
over-commented. It needs a lot of feedback, and most of that feedback is "cut this".

## Dispatch

The review runs in a **subagent with empty context**. The branch is large and the point is a
reader who owes none of it any loyalty — inherited context imports the weaker agent's
assumptions along with its code.

Dispatch one `general-purpose` subagent whose prompt has these four parts, in order:

1. `Read .agents/skills/branch-review/SKILL.md and follow it.`
2. The repo root as an absolute path.
3. `Derive the scope yourself from git. Fix directly; do not report back for approval.`
4. The return shape: `Return: the three passes' findings separately, net line delta,
   structural changes made, findings you deliberately left and why, and the final
   test/lint status.`

If a spec file and an implementation notes file exist for this work, add a fifth part: their
absolute paths, and `Read both before reviewing.` Paths only.

The prompt contains those parts and nothing else — no branch summary, no architecture tour,
no defense or critique of the existing design, no list of files you think matter. Everything
else the subagent needs is in the branch diff and in this skill.

When it returns: read the summary, verify `scripts/test.sh` and `scripts/lint.sh` pass
yourself, and relay the findings to the human — including the ones left for a behavior
decision.

---

Everything below is for the subagent.

## Scope

```bash
git merge-base HEAD master
git diff --stat $(git merge-base HEAD master)..HEAD
git log --oneline $(git merge-base HEAD master)..HEAD
```

Only unmerged changes. Uncommitted work counts too — `git diff HEAD` for tracked changes,
and `git status --short` for untracked files, which the diff never shows. Read those in full.
If the branch is master or the merge base is HEAD, say so and stop.

## Method — three passes, in order

Do not skip to pass 3. Most of the cuts live in pass 1, and finding them first makes
passes 2 and 3 much shorter.

**Pass 1 — Overall structure.** From the file list alone, before reading bodies:
Which modules are new? Does each earn its existence? Are any two doing the same job?
Does the layering hold (domain vs interface vs infrastructure; no `love` in `libs/rom` or
`libs/assets`)? Is there a module that is a thin wrapper over another? Cut or merge here first.

**Pass 2 — Per-file organization.** For each surviving file: does the header comment state
its role and name the authoritative source? Is the public surface minimal, or are internals
exported "for tests"? Are related functions adjacent? Is there dead or duplicated code
across files?

**Pass 3 — Per-function.** Now read bodies against
`.agents/skills/review-checklist.md`. Read that file. For **every** corner-case branch,
state explicitly: can it be cut, and what is the cost? Cut unless the cost is real and
reachable.

## Applying

Fix directly. Work file by file, smallest safe edits, running `scripts/test.sh` as you go —
not one giant rewrite at the end.

Then `scripts/lint.sh` (stylua + lua-language-server), fix every finding, re-run tests.

Finally summarize: cuts made (with line counts), renames, structural changes, and a short
list of findings you did *not* act on because they need a behavior change or a decision
from the human.

## Rules

- Less code is better code. Report net lines removed.
- Behavior-preserving only. A finding that requires changing behavior goes in the summary,
  not into the code.
- Do not defend the existing code because it exists. It was written under weaker judgment.
- Report honestly: if tests or lint fail at the end, say so with the output.

## Red flags

| Thought | Reality |
|---|---|
| "Let me just start reading files top to bottom" | Pass 1 first. Structural cuts delete whole files you'd otherwise review. |
| "This abstraction might be useful later" | One caller = inline it. Later is not a caller. |
| "This defensive branch is harmless" | It hides bugs and costs a test. Name what breaks if it's cut, or cut it. |
| "The diff is huge, I'll sample it" | Sampling a branch review is not a branch review. Say so instead of pretending. |
| "The previous agent probably had a reason" | Assume it didn't. Find the reason in the code or cut it. |
| "I'll list the findings and let the human fix them" | Fix them. List only what needs a behavior decision. |
