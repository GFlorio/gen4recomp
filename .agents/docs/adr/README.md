# Architecture Decision Records

ADRs preserve durable design rationale: a choice whose why is likely to be
revisited or whose tradeoffs constrain future work. They complement code,
tests, standing guidance, and public architecture prose; they do not replace
those authorities.

## When an ADR earns permanence

Write or update an ADR when one or more of these apply:

- future work is likely to reopen the same architectural choice;
- an intentional omission or restriction could otherwise look unfinished;
- the choice establishes a long-lived boundary, ownership model, persistence
  contract, or public/mod-facing surface;
- plausible alternatives are likely to be proposed again; or
- the choice accepts a known ceiling with a concrete reason to revisit it.

Do not use an ADR for implementation sequencing, temporary research, agent
reasoning transcripts, commit history, or local mechanical choices. If a rule
can be enforced mechanically, prefer the code, static gate, or test; retain the
ADR only when its rationale remains useful.

## Shape

```markdown
# ADR: <decision>

**Status:** Accepted | Superseded | Rejected
**Date:** YYYY-MM-DD
**Scope:** <what this constrains>

## Context
<Problem and evidence.>

## Decision
<Present-tense chosen architecture or contract.>

## Alternatives considered
- <alternative>: <why not>

## Consequences
<Costs, invariants, and non-guarantees.>

## Revisit when
<Concrete evidence or condition, or `No known trigger`.>
```

Accepted ADRs describe the current design in present tense. Supersede an ADR
when a later decision intentionally replaces it, linking both directions.
