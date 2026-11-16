# L16Studio

A fully native SwiftUI macOS app for viewing and converting RAW photos from
the [Light L16](https://en.wikipedia.org/wiki/Light_(company)) — the 16-lens
computational camera from Light Co. (defunct as of 2022). L16Studio reads the
L16's proprietary `.lri` RAW container directly, with no dependency on
Light's own (now unmaintained, buggy) Lumen desktop software.

Built from a clean-room Swift implementation of the `.lri` format, informed
by prior community reverse-engineering (see [Attribution](#attribution)
below) but not a port of any existing project's source.

## What it does

- **Library**: imports `.lri` shots into a browsable grid with flags, star
  ratings and filters. Files on disk are referenced where they are.
- **Camera import**: pulls shots straight off an L16 plugged in over USB.
- **Viewer**: every lens the camera fired for a shot (the L16 fires 10 of
  its 16 modules per shot) in a filmstrip, with native zoom and pan.
- **Colour**: uses Light's own per-lens factory calibration and the white
  balance the camera chose, through Apple's RAW pipeline (`CIRAWFilter`) via
  a DNG built from the decoded sensor data.
- **Fusion**: combines the lenses into one image, shown as "Fused" at the
  front of the lens strip. "Wide merge" combines the lenses that share the
  reference's focal length, including the mono lens (lower noise, 13 MP). "Full detail" then adds the
  telephoto lenses and crops to the shot's focal length, up to 52 MP.
- **Adjust**: exposure and white balance (temperature, tint), live.
- **Export**: any lens, or all of them, as DNG, JPEG or HEIC; the fused image
  as JPEG, HEIC or 16-bit TIFF.

**Not yet**: depth effects (refocusing, background blur), and reliable
telephoto detail at close range. Nobody in the L16 community has reproduced
Light's full fusion pipeline; this project is building its own in stages.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ installed (its toolchain compiles SwiftUI). It does not need to
  be the selected developer directory or set up beyond installing it.
- For camera import: `brew install libmtp` (macOS has no built-in support
  for the file-transfer protocol the camera uses)

## Install

```sh
git clone https://github.com/sunkencity999/L16Studio.git
cd L16Studio
./install.sh
```

This builds the app with the Swift toolchain, installs `L16Studio.app` to
`/Applications`, and installs an `l16studio` command-line launcher to the
first writable directory on your `PATH` (`/opt/homebrew/bin`,
`/usr/local/bin`, or `~/.local/bin`).

## Usage

Launch from Spotlight/Finder like any other app, or from the terminal:

```sh
l16studio                              # launch the app
l16studio path/to/photo.lri            # launch, import and open a file
```

Double-clicking a `.lri` file in Finder (or "Open With → L16Studio") works
the same way, since `.lri` is registered as a document type.

Inside the app:

- Drag `.lri` files or folders onto the window, or **File → Import…** (⌘I).
- **File → Import from Camera…** (⇧⌘I): plug the L16 in directly (not through
  a hub), wake it, and set its USB mode to file transfer.
- Double-click a shot to open it. Left/right arrows change lens, Esc returns
  to the library, double-click the image to switch between fit and 100%.
- Adjustments and export are in the inspector on the right (⌥⌘I).

Imported camera shots are stored in `~/Pictures/L16 Studio`. The library
index lives in `~/Library/Application Support/L16Studio`.

## Building from source (without install.sh)

```sh
scripts/build-app.sh          # -> build/L16Studio.app
swift build                   # just compile (set DEVELOPER_DIR to Xcode's
                              # Developer folder if only CLT is selected)
```

There is no Xcode project: the app is a SwiftPM executable (`Package.swift`)
and `scripts/build-app.sh` assembles the bundle, icon and `Info.plist`.

### LRIKit

The `.lri` parsing/rendering engine is a standalone Swift package
(`LRIKit/`) with no dependency on the app itself, plus a CLI diagnostic tool:

```sh
cd LRIKit
swift build
swift run lriprobe /path/to/file.lri
```

`lriprobe` prints per-capture metadata, unpacks pixel data, and (for the
reference camera) writes a debug preview PNG, a real DNG, and rendered
JPEG/HEIC files. Add `--thumbs` to render a small JPEG of every colour lens,
which is the quickest way to compare lenses side by side, or `--fuse` to
run the wide merge (`<name>_fused.tif`/`.jpg`), or `--fuse-tele` for the
full-detail fusion (`<name>_fused_tele.jpg`; `--scale=2` for a smaller one).

## Known limitations

- **Fusion is conservative**: a lens is left out wherever it doesn't line up
  with the reference. Far scenes gain real resolution from the telephoto
  lenses; at close range they mostly don't line up, so the result there is
  close to the wide merge enlarged.
- **Full-detail fusion needs a lot of memory** (around 8 GB at 52 MP). On
  Macs with less than 24 GB the app starts on the wide merge.
- **`RAW_BAYER_JPEG` pixel format is implemented but unvalidated**: it's
  coded to the documented spec, but no capture from the camera used for
  testing uses it (all use 10-bit packed), so such captures aren't rendered.

Full technical notes and validation history are in `PROGRESS.md`.

## Project layout

```
Package.swift        The app as a SwiftPM executable
L16Studio/           SwiftUI app (library, viewer, inspector, camera import)
LRIKit/              Standalone Swift package: .lri parsing, DNG/colour
                     pipeline, lens renderer, lriprobe CLI
scripts/build-app.sh Builds and assembles L16Studio.app
install.sh           Build + install to /Applications, plus CLI launcher
icon-gen/            CoreGraphics app-icon generator (kept for regeneration)
```

## Attribution

The `.lri` protobuf message definitions
(`LRIKit/Sources/CLRIProto/*.proto`) are reused from prior reverse-engineering
work, not authored here:

- [gennyble/lri-rs](https://github.com/gennyble/lri-rs) (ISC License) —
  format documentation and block-parsing approach
- [dllu/lri-rs](https://github.com/dllu/lri-rs) (MIT License, Daniel
  Lawrence Lu) — original protobuf definitions

Full details in `LRIKit/Sources/CLRIProto/ATTRIBUTION.md`. All Swift parsing,
rendering, and app code is an original implementation for this project.

## License

MIT — see `LICENSE`.
