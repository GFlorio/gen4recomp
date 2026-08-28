# Architecture Decision Records

`docs/adr/` stores durable design rationale: decisions whose **why** is likely to be revisited
or whose tradeoffs constrain future work. ADRs complement current-state architecture docs;
they do not replace them.

Do not write an ADR for every non-trivial change. Prefer code, tests, `AGENTS.md`, or a normal
current-state doc when those are the authoritative home for the fact.

## When an ADR earns permanence

Write or update an ADR when at least one is true:

- future work is likely to reopen the same architectural choice;
- an intentional omission/restriction will otherwise look like an unfinished feature;
- the choice establishes a long-lived boundary, ownership model, persistence contract, or
  public/mod-facing surface;
- multiple plausible alternatives exist and the rejected alternatives are likely to be
  proposed again;
- the decision deliberately accepts a known ceiling/tradeoff that has a concrete revisit
  trigger.

Do not use an ADR for temporary implementation sequencing, task/spec IDs, agent reasoning
transcripts, commit-by-commit history, or local mechanical choices.

## New ADR shape

Use a descriptive filename and keep the record about the decision, not the implementation
process:

```markdown
# ADR: <decision>

**Status:** Accepted | Superseded | Rejected
**Date:** YYYY-MM-DD
**Scope:** <what this constrains>

## Context
<Current problem and evidence that make the decision necessary.>

## Decision
<Present-tense statement of the chosen architecture/contract.>

## Alternatives considered
- <alternative>: <why not>

## Consequences
<Important costs, invariants, and non-guarantees created by the decision.>

## Revisit when
<Concrete evidence/condition that would justify reopening the decision, or `No known trigger`.>
```

`Alternatives considered` is mandatory for new ADRs when a real alternative existed.
`Revisit when` is mandatory for deliberate simplifications with a known ceiling; name the
observable trigger, not "if needed later".

## Lifecycle

- Accepted ADRs describe shipped/current design in present tense. Keep plans and temporary
  acceptance checklists out once the decision is implemented.
- Supersede an ADR rather than silently rewriting history when a later architectural decision
  intentionally replaces it. Link both directions.
- If implementation details evolve without changing the decision, update current-state docs
  or code, not the ADR.
- If a rule becomes mechanically enforceable, prefer the code/static gate/test as enforcement;
  the ADR may remain only when its rationale still matters.
