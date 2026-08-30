# libs/script Agent Guidance

Read root `AGENTS.md` first. `libs/script` is the internal implementation behind the
public `gen4.script` mod-script entry point. It owns the project DSL, compiler, runtime,
scheduler, task substrate, registry, and mod-loader mechanics.

## Boundary

Generic script execution must not embed HGSS field meanings. Game-specific values,
conditions, references, and services enter through explicit collaborators supplied by the
HGSS runtime. The package owns script mechanics; it does not own field, story, or
application policy.

The package may depend on foundation libraries and `libs/assets` where the current script
or generated-data contract requires it. It must not depend on `libs/nds`, `libs/hgss`,
`game`, or `romdump`. Internal `libs.script` paths are not additional mod-facing APIs;
`gen4.script` remains the compatibility surface.
