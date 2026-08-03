# Code Agent Guidance

This file provides guidance to Coding Agents when working with code in this repository.

## General Guidelines

- Be brief.
- Strongly bias towards simplicity.
- Strongly bias towards asking for clarification.
- Less code is better code.
- Be concrete.
- Look for opportunities for refactoring or trimming code at the end of each task.
- Flat is better than nested.
- Look for root causes.
- Descriptive names.
- Make liberal use of assertions to enforce assumptions and invariants.
- Throw instead of returning error codes or nil.
- Aggressively remove dead code, no "just in case" compatibility.
- Tests first, but ask before testing boundaries.


## Architecture

1. Work in three layers: interface, domain, and infrastructure.
1.1. Domain contains all the game logic and should be testable independently of LÖVE.
1.2. Interface and infrastructure can depend on LÖVE, but should be kept as thin as possible.
1.3. Game modability is essential, so each layer should expose clear hook points for modders to extend the game without modifying the core code.


## Commands

- Prefer running scripts from the scripts directory instead of ad-hoc commands.
- If there isn't a script for a common task, bias towards creating one.
- When authoring scripts, assume a UNIX-like environment.

When calling skills or any commands, prefer a direct syntax (avoiding e.g. variable substitution)
to avoid shell injection or permission issues.

## Commits

- Use *Scoped Commits*: `<scope>: <description>`
- Do not add `Co-Authored-By` trailers or any AI attribution. The human is solely responsible for all commits.

