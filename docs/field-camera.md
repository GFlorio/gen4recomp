# Field camera and host presentation

The gameplay camera keeps HGSS's field-camera data as its source of truth while
letting the host presentation reveal more world and apply bounded zoom. Camera
geometry and host presentation are separate contracts.

## ROM-derived camera

`romdump/src/digest/HgssCameraTable.lua` decodes the 17 records stored in ARM9
overlay 1 (discovered by `FieldCameraDiscovery`); the generated profiles are
published through the `libs/assets/src/FieldCameraCache.lua` contract that the
runtime reads. The record layout and initialization behavior follow
`pret/pokeheartgold`'s
`src/camera.c` and field overlay assembly. Each normalized profile retains its
projection type, distance, X/Y angles, half FOV, clipping planes, and target
offset. `FieldCamera` derives the eye from those values:

```text
horizontal = distance * cos(angleX)
eye.x = target.x + sin(angleY) * horizontal
eye.y = target.y + sin(-angleX) * distance
eye.z = target.z + cos(angleY) * horizontal
```

Player X/Z deltas apply immediately. Y deltas pass through the original
seven-entry, six-frame `CameraHistory` delay. Zoom never changes the eye,
target, authored distance, angles, or history.

`FieldCamera:billboardProjection()` is the projection field billboards draw
through (HGSS `ov01_021E6220`; see rendering.md for the source mechanics):
the normal projection with the DS's fixed 0.5-tile depth pull scaled by
`cos(angleX)` added into the Z-row translation. Only actor billboards use it;
everything else keeps `projection()`.

## Aspect and safe area

The canonical composition is 4:3. Expanded mode preserves the centered 4:3
reference frame and reveals more world horizontally on wider hosts. Strict mode
fits that 4:3 frame and letterboxes or pillarboxes the remainder. Hosts narrower
than 4:3 also use the fitted frame.

Future field UI should anchor composition-sensitive elements to
`FieldViewport.referenceFrame`. Backgrounds and nonessential decoration may use
`worldViewport`; they must not assume that its edges are inside the 4:3 safe
area.

`FieldCamera:canonicalProjection()` is always the unzoomed 4:3 projection for
parity/crop comparisons. Normal gameplay uses the current aspect and zoom.

## Configurable zoom

The tuning lives in `data/manifests/field_presentation.lua` (current values:
`referenceHeight = 600`, `resizeCompensation = 0.7`, `minZoom = 0.5`,
`maxZoom = 1.5`, `step = 0.1`, default `manualZoom = 1`). Both orthographic
and perspective cameras apply zoom to projection X/Y scale only. The effective
zoom is:

```text
resizeZoom = (referenceHeight / viewportHeight) ^ resizeCompensation
effectiveZoom = clamp(manualZoom * resizeZoom, minZoom, maxZoom)
```

`resizeCompensation` is the requested split between resizing objects and
revealing more world vertically:

- `0` keeps the old framing, so pixel size changes fully with window height;
- `1` keeps approximate object pixel size until a zoom bound is reached;
- an intermediate value shares the change between both effects.

With the current `0.7` compensation, going from 600 to 900 therefore changes
object pixel size by about `1.5^0.3` instead of `1.5`. `-` and `=` adjust
manual zoom; `0` restores its configured default. Coverage planning uses
effective zoom, so zooming out requests the newly visible cells.

## Field-attached UI scale

Field-attached dialogue and signpost presentation follow the same effective
zoom as the world:

```text
fieldScale = FieldViewport:logicalPixelScale(camera.zoom)
           = (referenceFrame.height / 192) * effectiveZoom
```

The logical 256x192 surface is bottom-centered in `referenceFrame`:

```text
originX = referenceFrame.x + (referenceFrame.width  - 256 * fieldScale) / 2
originY = referenceFrame.y + referenceFrame.height - 192 * fieldScale
```

Logical geometry (box at `16,152,216,32`, text rects, cursor, wipe offset)
stays in canonical 256x192 pixels; renderers translate by `origin` and scale
by `fieldScale` exactly once. Zoom and resize compensation therefore affect
world and field-attached UI through the same `camera.zoom` value, and wider
expanded hosts still center the UI in the 4:3 `referenceFrame`, not across the
extra revealed world width. Start Menu, Trainer Card, script menu, and other
application surfaces keep their existing placement contracts and do not follow
field zoom.

## Validation and known gaps

Run `scripts/test.sh` for projection, history, viewport, resize, coverage, and
cache ownership contracts. An imported cache additionally enables the ROM-gated
layer of that same command.

Deferred parity includes dynamic/script cameras, exact overlapping-surface
tie-breaking outside the target staircase, aspects narrower than 4:3 as a
gameplay target, final responsive HUD layout, and DS bottom-screen UI.
