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

- Opens `.lri` files and lists every capture inside (the L16 fires all 10
  active lens modules — sometimes more in an HDR burst — into one file)
- Shows per-shot metadata: focal length, lens/module count, per-camera CFA
  and calibration info
- Renders full-resolution previews using Apple's own RAW pipeline
  (`CIRAWFilter`) via a hand-rolled DNG container built from the decoded
  sensor data — no custom demosaic code to maintain
- Exports any capture to DNG, JPEG, or HEIC

**Out of scope for v1**: true 16-lens computational fusion (super-resolution
zoom, HDR merge, depth-based effects). Nobody in the L16 community —
including the most active reverse-engineering projects — has cracked
Light's fusion pipeline. L16Studio's goal is to be a great single-shot RAW
viewer/converter, not to reimplement Light's cloud processing.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ (full Xcode, not just Command Line Tools — needed to build)

## Install

```sh
git clone https://github.com/sunkencity999/L16Studio.git
cd L16Studio
./install.sh
```

This will:
1. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) via Homebrew if
   it isn't already present
2. Generate the Xcode project from `project.yml`
3. Build a Release configuration of the app
4. Install `L16Studio.app` to `/Applications`
5. Install an `l16studio` command-line launcher to the first writable
   directory on your `PATH` (`/opt/homebrew/bin`, `/usr/local/bin`, or
   `~/.local/bin`)

## Usage

Launch from Spotlight/Finder like any other app, or from the terminal:

```sh
l16studio                              # launch the app
l16studio path/to/photo.lri            # launch and import a file directly
```

Double-clicking a `.lri` file in Finder (or "Open With → L16Studio") works
the same way, since `.lri` is registered as a document type.

Inside the app: drag `.lri` files onto the window, or use **File → Open…**
(⌘O). Select a capture in the gallery to view it full-resolution, then use
the export menu to save as DNG/JPEG/HEIC.

## Building from source (without install.sh)

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project L16Studio.xcodeproj -scheme L16Studio -configuration Release build
```

The `.xcodeproj` and `L16Studio/Info.plist` are generated artifacts (gitignored)
— `project.yml` is the single source of truth. Re-run `xcodegen generate`
after pulling changes that touch it.

### LRIKit

The `.lri` parsing/rendering engine is a standalone Swift package
(`LRIKit/`) with no dependency on the app itself, plus a CLI diagnostic tool:

```sh
cd LRIKit
swift build
swift run lriprobe /path/to/file.lri
```

`lriprobe` prints per-capture metadata, unpacks pixel data, and (for the
reference camera) writes a debug preview PNG, a real DNG, and a
`CIRAWFilter`-rendered PNG — useful for debugging the format itself
independent of the SwiftUI app.

## Known limitations

- **Color accuracy**: Light's own calibration matrices (per-shot
  `ColorMatrix`/`ForwardMatrix`) don't map cleanly onto DNG's colorimetric
  conventions when fed to `CIRAWFilter` — they currently produce a heavy
  green cast, so a generic sRGB D65 matrix is used instead. Renders are
  correct in structure (no demosaic artifacts) but not color-accurate to
  the original scene yet. See `LRIKit/Sources/LRIKit/DNGWriter.swift` and
  `PROGRESS.md` for details.
- **`RAW_BAYER_JPEG` pixel format is implemented but unvalidated**: it's
  coded to the documented spec, but no real capture on the camera unit
  used for testing produces this format (all captures use the more common
  10-bit packed format), so the plane-to-CFA-position assembly is a
  best-guess pending a real sample.

Full technical notes and validation history are in `PROGRESS.md`.

## Project layout

```
L16Studio/          SwiftUI app (views, view models)
LRIKit/              Standalone Swift package: .lri parsing, debayer/DNG
                     pipeline, lriprobe CLI
icon-gen/            CoreGraphics app-icon generator (kept for regeneration)
install.sh           Build + install script
project.yml          XcodeGen project spec (source of truth for the .xcodeproj)
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
