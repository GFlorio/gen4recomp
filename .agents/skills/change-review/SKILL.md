---
name: change-review
description: Use when work on a task is finished and about to be committed — a critical review and cleanup pass over the uncommitted working diff, followed by lint.
---

# Change Review

A pre-commit critical review and cleanup pass over the **uncommitted** changes.
Scope is small, so fix as you go rather than reporting.

## Dispatch

The review runs in a **subagent with empty context**. A fresh reader judges the diff on its
own merits; the author's context is exactly the bias being reviewed away.

Dispatch one `general-purpose` subagent whose prompt has these four parts, in order:

1. `Read .agents/skills/change-review/SKILL.md and follow it.`
2. The repo root as an absolute path.
3. `Derive the scope yourself from git. Fix directly; do not report back for approval.`
4. The return shape: `Return: files changed, net line delta, what you cut, what you
   renamed, findings you deliberately left and why, and the final test/lint status.`

If a spec file and an implementation notes file exist for this work, add a fifth part: their
absolute paths, and `Read both before reviewing.` Paths only.

The prompt contains those parts and nothing else — no summary of the feature, no motivation,
no "I was working on X", no list of files you think matter. Everything else the subagent
needs is in the diff and in this skill.

When it returns: read the summary, verify `scripts/test.sh` and `scripts/lint.sh` pass
yourself, and relay the findings to the human. Findings the subagent left for a behavior
decision are yours to raise, not to silently drop.

---

Everything below is for the subagent.

## Scope

```bash
git status --short
git diff HEAD          # tracked changes
```

Untracked files are in scope too — `git status --short` lists them; read them in full.
Nothing already committed is in scope. If the diff is empty, say so and stop.

## Method

1. **Read the whole diff first.** No edits yet.
2. **Review against the checklist** in `.agents/skills/review-checklist.md`. Read it.
3. **Apply the fixes.** Cut first, then rename, then restructure. Keep each edit small.
4. **Run `scripts/test.sh`.** Fix what breaks.
5. **Run `scripts/lint.sh`** (stylua + lua-language-server) and fix every finding.
6. **Re-run `scripts/test.sh`** after the lint fixes.
7. **Summarize**: what you cut, what you renamed, what you deliberately left and why.

## Rules

- Less code is better code. A pass that only adds lines is a failed pass.
- Fix, don't propose. This runs on your own fresh work — you have the context.
- Behavior-preserving only. If a finding needs a behavior change, list it in the summary
  instead of doing it.
- Report honestly: if tests or lint still fail at the end, say so with the output.

## Red flags

| Thought | Reality |
|---|---|
| "The diff is small, skip the checklist" | Small diffs are where magic literals and debug prints survive. Read it. |
| "That branch might be needed later" | No caller reaches it. Cut it; git remembers. |
| "I'll leave the print, it's useful" | Debug code is residue. Cut it. |
| "lua-language-server is being pedantic" | Add the annotation. That's the finding. |
| "I'll fix lint by disabling the check" | Name why the analyzer is wrong, or fix the code. |
