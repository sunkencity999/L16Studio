# L16Studio progress notes

## LRIKit (Swift package, Sources/CLRIProto + Sources/LRIKit)

Native Swift parser for Light L16 `.LRI` RAW files, replacing dependence on
Lumen for anything except true multi-lens fusion (which nobody -- including
the most active community reverse-engineering project -- has cracked; see
the research summary that kicked off this project).

### Validated against real capture data (2026-07-29)

Pulled real `.lri` files directly off Christopher's L16 (rooted this same
session) via `adb pull` into `test-data/` (gitignored, not real work product
to keep in the repo):
- `L16_00308.lri`, `L16_00118.lri` -- ordinary single shots, 10 active modules
- `L16_00001.lri` -- an HDR burst, 40 images = 4 exposures x 10 modules
- `calibration.lri` -- factory calibration-only file, 0 images (correctly
  parsed as empty, no crash)

All four parsed cleanly: correct module count, correct 4160x3120 (13MP)
AR1335 sensor dimensions, correct per-shot CFA `sensor_bayer_red_override`
values, correct color-calibration-profile counts (3 for color modules, 0 for
the mono module), and packed10bpp byte counts that match
`width * height * 10 / 8` exactly.

**Real proof, not just clean stats**: unpacked `L16_00308.lri`'s reference
camera (`a1`) through the `unpackTenBit` port, ran a crude quick-and-dirty
2x2 downsample (not the real debayer pipeline -- that's task #17), and wrote
it to PNG. It's a real, recognizable photo of a room (window, curtains,
cabinets -- upside down, which is just raw sensor mounting orientation, to
be corrected in the real pipeline). This proves the unusual bit-packing
port (reverse-the-whole-buffer-then-chunk-by-5-bytes) is byte-order-correct,
not just "in range."

### Known gap: RAW_BAYER_JPEG is unvalidated against real data

Implemented per the documented spec (`BayerJPEG.swift`): decodes the
4-JPEG-plane color format / 1-JPEG mono format via ImageIO, with a
best-guess (row-major 2x2 tile) plane-to-CFA-position assembly clearly
flagged as unconfirmed -- the community itself doesn't know the true
ordering, or even what triggers the camera to use this format over plain
packed10bpp. **None of the ~280 `.lri` files on this specific unit use
BayerJPEG** (checked file sizes across the whole camera roll via `adb`;
all are >= the packed10bpp baseline size, and BayerJPEG should compress
smaller). If we ever find or produce a real BayerJPEG sample, re-verify
the plane ordering against it before trusting color output from that path.

## Debayer / color pipeline (task #17, 2026-07-29)

**Architecture decision**: rather than write our own GPU demosaic kernel,
`DNGWriter.swift` builds a minimal, valid "mosaiced raw" DNG file (hand-rolled
TIFF writer in `TIFFWriter.swift`, no external dependency) from a decoded
`RawImage` + its CFA pattern, then hands off to Apple's own `CIRAWFilter`
(ImageIO/RawCamera.framework) to debayer, apply the color matrix, and render
-- macOS already has a mature, hardware-accelerated raw pipeline; no reason
to reimplement demosaicing ourselves. This also means most of task #18 (DNG
export) is already done as a side effect of building this.

**Validated against real data**: `CIRAWFilter` accepted our hand-written DNG
and rendered a full 4160x3120 color image with clean, alias-free demosaicing
-- this conclusively proves the CFA-pattern-from-`sensor_bayer_red_override`
logic (`CFAPattern.swift`) is correct, since a wrong CFA guess produces
obvious checkerboard/moire artifacts, not clean edges.

**Known open issue -- color accuracy**: Light's own calibration matrices
(`forwardMatrix`/`colorMatrix` from `ColorInfo`) produce a heavily saturated
green cast when fed to `CIRAWFilter` as `ColorMatrix1`, tried both directly
and inverted. Likely cause: those matrices were calibrated for Light's own
proprietary `CIAPI`/`libcp` rendering pipeline (see the LRI-format research
summary), not for DNG's specific colorimetric convention -- may need a
different combination/normalization than DNG expects. A generic sRGB D65
XYZ->camera matrix produces a far more plausible (if not color-accurate)
result and is the current default. Also: `CIRAWFilter` appears to ignore our
`AsShotNeutral` tag entirely (real calibration values vs. identity produced
near-identical renders) -- needs investigation, possibly a `CIRAWFilter`
option needs to be set explicitly. Both are documented inline in
`DNGWriter.swift`'s doc comment. Real photos, not accurate colors yet --
appropriate for continued iteration, not a v1 blocker.

## Tools

- `swift run lriprobe <file.lri> [...]` -- CLI inspector: prints metadata,
  per-image dimensions/sensor/calibration, unpacks pixels and reports
  min/max/mean, and (for the reference camera) writes a debug preview PNG,
  a real DNG, and a `CIRAWFilter`-rendered PNG from that DNG.

## SwiftUI app shell (task #19, 2026-07-29)

A real, native macOS app (`L16Studio.app`), project generated via `xcodegen`
(`project.yml` is the source of truth -- run `xcodegen generate` after
cloning; `.xcodeproj` and the generated `Info.plist` are gitignored). Views:
`ContentView` (sidebar + drag-and-drop import), `ShotGalleryView` (per-shot
metadata header + thumbnail grid), `CaptureThumbnailView` (async fast-draft
render per tile), `CaptureDetailView` (full-res render + export menu).

**Fully validated end-to-end through the actual built app**, not just the
CLI tool -- launched it, imported a real `.lri` file via File > Open,
confirmed the gallery showed the correct capture count (9 of 10, correctly
excluding the mono module) and metadata (56mm, 9 lenses), opened a capture's
detail view (full-res debayer), and exported a real JPEG via the Export
menu's save panel -- verified the resulting file on disk is a valid
4160x3120 JPEG.

**Bug found and fixed during this validation**: `.lri` isn't a
system-registered UTType, so `UTType(filenameExtension: "lri")` silently
failed and the Open panel's file filter showed everything (not nothing).
Fixed by declaring a proper `UTImportedTypeDeclarations` entry in
`project.yml` (`dev.sunkencity.L16Studio.lri`) and referencing that type
identifier directly in `LibraryModel.swift` -- confirmed fixed by checking
Documents (showed all files greyed out except `.lri`) and navigating
directly to a real `.lri` file (showed enabled, with a proper "Light L...
Image" kind label).

**Known limitations carried over from earlier tasks, not fixed here**: color
accuracy (generic sRGB matrix placeholder, not Light's own calibration) and
BayerJPEG-format captures (excluded from the gallery via `renderableImages`
filtering) -- both documented in `ImageRenderer.swift`/`DNGWriter.swift`.
