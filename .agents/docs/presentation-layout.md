# Dual-screen presentation layout policy

This policy describes how interfaces derived from Nintendo DS software adapt
source main and auxiliary screen roles to host displays. It defines
presentation intent, not a universal widget or layout API.

## Source semantics and host placement

The main surface is the source upper-screen role: world or primary visual
context, characters, and essential information. The auxiliary surface is the
source lower-screen role: supporting information and interaction controls,
including touch-oriented controls when a feature has them.

The roles remain meaningful when their physical placement changes. Rendering
and pointer handling must use the same host placement result. The original
screen coordinate space is semantic reference information for art and
behavior, not a requirement to render a hidden fixed-size canvas on every host.

For field presentation, preserve a stable source reference frame and safe area
for essential world context. Host scaling may reveal, crop, or reposition
nonessential presentation, but it must not make simulation coordinates depend
on window size or hide required controls.

## Host presentation strategies

| Host arrangement | Default strategy | Feature guidance |
| --- | --- | --- |
| Physical dual-screen | Separate main/world and auxiliary surfaces | Preserve source separation and relative intent. |
| Single portrait display | Main above auxiliary | Keep roles distinct and in source-like order unless interaction or readability requires an adjustment. |
| Single wide display | Side by side | Use horizontal space without collapsing the roles into one undifferentiated panel. |
| Constrained single display | Feature-specific controls-first composition | Retain essential main context and usable auxiliary controls; reduce or crop only nonessential content. |

A feature with no meaningful auxiliary content need not invent a second panel.
Transient decorative content may overlap only when it cannot obscure active
controls or essential state. Both source roles must not be blindly composited at
the same coordinates.

## Feature-local layout responsibility

Each feature makes placement decisions from the host topology and viewport
information available to it. Drawing and hit-testing consume the same resulting
regions. Exceptions to the defaults are justified by interaction or readability
needs, not accidental implementation constraints.

`ScreenTopology` describes host capabilities and surfaces, including semantic
roles, rectangles, safe rectangles, and touch capability. It is an input to
feature layout decisions, not a policy engine or universal layout selector.

Hand-crafted feature-local layouts are preferred while adaptations remain
isolated. Consider a reusable layout mechanism only after several features
demonstrate the same stable classification, placement, input-mapping, and
accessibility needs.
