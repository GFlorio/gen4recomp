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

- Work in three layers: interface, domain, and infrastructure.
- Domain contains all the game logic and should be testable independently of LÖVE.
- Interface and infrastructure can depend on LÖVE, but should be kept as thin as possible.
- Game modability is essential, so each layer should expose clear hook points for modders to extend the game.


## Commands

- Prefer running scripts from the scripts directory instead of ad-hoc commands.
- If there isn't a script for a common task, bias towards creating one.
- When authoring scripts, assume a UNIX-like environment.

When calling skills or any commands, prefer a direct syntax (avoiding e.g. variable substitution)
to avoid shell injection or permission issues.

## Commits

- Use *Scoped Commits*: `<scope>: <description>`
- Do not add `Co-Authored-By` trailers or any AI attribution. The human is solely responsible for all commits.

## Code Conventions

- **Layout:** pure domain modules live in `src/import/` and `src/core/`; they must not `require` love. Require siblings by full path: `require("src.import.BinaryReader")`.
- **Module shape:** each file returns one table. Instance types set `M.__index = M` and construct with `setmetatable({...}, M)`. 2-space indent, LF, final newline.
- **Header comment:** open each module with a short paragraph stating its role. Where it implements an external binary format, name the authoritative source (a GBATEK section, a `pret/pokeheartgold` file, or a `docs/` page) rather than an internal document.
- **Zero-based everywhere:** offsets, `fileId`, `memberId`, overlay tables. Iterate zero-based maps with `for id = 0, count - 1`, never `ipairs`. Never expose a generic `id`; use `narcId` / `fileId` / `memberId`.
- **Binary access:** go through `BinaryReader` (bounds-checked, zero-based, little-endian by arithmetic). No `bit`/Lua 5.3 ops needed for 8/16/32-bit values.
- **Errors vs assert:** malformed input / user faults raise `Errors.raise(CODE, message, context)` with a `SCREAMING_SNAKE_CASE` module-prefixed code (`NDS_*`, `OVERLAY_*`, `READ_*`). Programming invariants use plain `assert`. Public `open`/`parse` entry points wrap a private `_parse` in `pcall` and return `nil, err` when `Errors.is(result)`, else re-raise.
- **Tests:** each `tests/*_test.lua` returns a table of `name -> function`; register new modules in `tests/run.lua`'s `MODULES` list. Use `tests/support/Assert`; reuse the local `throwsCode(code, fn)` helper pattern to assert a raised `Errors` object with a given code. Put binary fixture generators in `tests/support/`. Run with `scripts/test.sh`.

