# Upstream provenance

This directory contains a mechanically reduced snapshot of the LuaCATS LÖVE
type declarations.

Only API/interface metadata needed for static analysis is retained, including
module and type names, function signatures, parameter and return types,
overloads, inheritance relationships, aliases, and enum values.

Human-readable documentation prose from the upstream generated files has been
intentionally removed. In particular, free-form documentation comments and
the descriptive `# ...` portions of LuaCATS annotations are not redistributed.

The original snapshot provenance follows.

# LuaCATS LÖVE definitions

- Upstream repository: https://github.com/LuaCATS/love2d
- Upstream commit: c630dd883cda128a19d850bd5e3911110b271609
- Vendored subtree: library/
- Upstream library tree: 289690a0a0d602693157ffb1f782acd7fcf4aa57
- LÖVE API version: 11.5

`library/` is an unmodified snapshot of that upstream subtree. Do not hand-edit
vendored definitions. Update by replacing the whole subtree from a deliberately
chosen upstream commit and updating the provenance above in the same change.

The researched upstream snapshot contains no license file. This provenance file
does not infer or assert licensing terms that upstream does not publish.
