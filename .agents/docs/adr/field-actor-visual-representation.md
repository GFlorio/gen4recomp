# ADR: field-actor visual representation

**Status:** Accepted
**Date:** 2026-08-05
**Scope:** how HGSS field-actor graphics cross from ROM-specific production into
runtime-drawable assets

## Context

HGSS field actors are described by source records that resolve through Nitro
model, texture, palette, and animation data. Ordinary actors use a shared
camera-facing billboard, while static map objects retain source geometry.
Carrying those source formats and their runtime state into gameplay would make
the reusable runtime depend on producer knowledge and require a specialized
animation path.

The runtime needs drawable geometry, textures, poses, timing, and semantic
placement. Source member identities, packed fields, lookup tables, and other
producer facts remain useful for compilation and provenance but are not runtime
contracts.

## Decision

The producer normalizes billboard actors into a private atlas plus declarative
pose/timing data and emits `renderKind = "atlas"`. Static map-object models use
`renderKind = "staticModel"` and retain their source geometry and polygon
state. The atlas normalizes texture data; it does not replace the source quad,
placement, or render-state facts needed by the runtime.

The generated runtime definition contains only the semantic data required for
drawing and animation. Source-specific resolution and provenance stay in
`romdump`; reusable runtime code consumes the generated asset without Nitro
knowledge.

## Alternatives considered

- Carry Nitro model/texture state into runtime: rejected because it duplicates
  producer knowledge and creates a general field-model animation subsystem for
  no current runtime capability.
- Hand-author a generic billboard: rejected because it can silently diverge
  from source geometry, placement, UVs, or polygon state.

## Consequences

Runtime rendering uses the ordinary image/quad path and keeps resource lifetime
bounded to generated assets. Compilation remains responsible for resolving
source animation ranges and preserving the semantic timing and direction data
the runtime needs. Producer-side provenance can explain or reproduce an asset
without expanding the mod-facing contract.

This intentionally does not claim that every future Nitro visual belongs in an
atlas. A source form that carries meaningful geometry or a distinct runtime
capability may need a separate generated representation.

## Revisit when

Revisit if a current feature requires runtime behavior that cannot be expressed
by generated atlas/static-model assets, or if multiple consumers demonstrate a
stable need for a shared Nitro-derived animation mechanism.
