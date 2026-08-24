# Dual-screen presentation layout policy

This policy describes how interfaces derived from Nintendo DS software adapt the
source main and auxiliary screen roles to the display surfaces available on the
host. It defines presentation intent, not a universal widget or layout API.

## Source semantics and host placement

The **main surface** is the source upper-screen role. It carries the world or
primary visual context, characters, and essential information. The **auxiliary
surface** is the source lower-screen role. It carries supporting information and
interaction controls, including touch-oriented controls when a feature has them.

These roles remain meaningful when their physical placement changes. A feature's
renderer and its pointer or touch handling must use the same host-native
placement result. Source coordinates, including the original 256×192 coordinate
space, are semantic reference information for art and behavior; they are not a
requirement to render a hidden fixed-size DS canvas on every host.

## Host presentation strategies

| Host arrangement | Default strategy | Feature guidance |
| --- | --- | --- |
| Physical dual-screen | Source-like, with separate main/world and auxiliary surfaces | Preserve the source separation and relative intent as closely as practical. Explicit surface roles take precedence over the window's aspect ratio. |
| Single portrait display | Vertically related, with main above auxiliary or the corresponding source-like order | Treat the viewport as one display even when it is physically large. Keep the two roles distinct and stack them in a DS-like relationship unless a feature has a concrete interaction or readability reason to adjust it. |
| Single wide display | Side by side | Use the available horizontal space for separate main and auxiliary regions. Small feature-specific adjustments are acceptable for readability and input, but do not collapse the two source roles into one undifferentiated panel. |
| Constrained single 4:3 display | Feature-specific controls-first composition | Keep the auxiliary interaction usable while retaining essential main-surface information. A feature may reduce, crop, reposition, or deemphasize nonessential main presentation, but it must not hide required context or controls. There is no universal mapping or aspect-ratio threshold. |

A feature with no meaningful auxiliary content does not need to invent a second
panel. A constrained display may overlap transient decorative content only when
that content does not obscure active controls or essential state. It must never
blindly composite both source screens at the same coordinates.

## Feature-local layout responsibility

Each feature should make its own placement decisions from the host topology and
viewport information available to it. The feature owns the resulting main and
auxiliary regions, and the drawing and hit-testing paths consume those same
regions. Exceptions to the defaults should be justified by interaction or
readability needs, rather than by accidental implementation constraints.

`ScreenTopology` is the existing description of host capabilities and surfaces,
including semantic roles, rectangles, safe rectangles, and touch capability. It
is an input to feature layout decisions, not a policy engine and not a universal
layout selector. It remains unchanged by this policy.

Hand-crafted, feature-local layouts are preferred while the project has only
isolated concrete adaptations. A reusable layout framework should be considered
only after several features demonstrate the same stable classification,
placement, input-mapping, and accessibility needs. Until then, adding a generic
framework would obscure feature semantics and impose assumptions that may not
fit another source-screen composition.
