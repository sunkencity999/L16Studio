# L16Studio

Software to keep the [Light L16](https://en.wikipedia.org/wiki/Light_(company))
useful: the 16-lens computational camera from Light Co. (defunct as of 2022).

- **L16Studio for macOS**: a native SwiftUI app that reads the L16's
  proprietary `.lri` RAW container directly, fuses its lenses into one image,
  and manages, adjusts and exports the results, with no dependency on
  Light's own (now unmaintained) Lumen desktop software.
- **L16 Studio for the camera**: a small Android app that runs on the L16
  itself, with a gallery, an editor and cable-free transfer to the Mac.

Built from a clean-room Swift implementation of the `.lri` format, informed
by prior community reverse-engineering (see [Attribution](#attribution)
below) but not a port of any existing project's source.

## What it does

- **Library**: imports `.lri` shots into a browsable grid with flags, star
  ratings and filters. Files on disk are referenced where they are.
- **Camera import**: pulls shots straight off an L16, over USB or over Wi-Fi
  (with the on-camera app below).
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
- **Looks**: Auto measures each picture's tonal range, mid-tones and colour
  cast and corrects them; Vivid, Golden, Crisp, Film and Mono build on that,
  with sliders to fine-tune. They apply to single lenses and to the fused
  image, and are the same looks as the on-camera editor.
- **Export**: any lens, or all of them, as DNG, JPEG or HEIC; the fused image
  as JPEG, HEIC, 16-bit TIFF or DNG. The merged DNG is a "linear raw"
  file: the merge itself with no tone curve or look applied, so Lightroom,
  Capture One or Photos open it with the editing range of a raw file.
- **Automatic import over Wi-Fi**: a switch in the sidebar. While it is on
  and the camera has Wi-Fi transfer running on the same network, each shot
  arrives in the library a few seconds after it is taken. The first time a
  camera is seen, the shots already on it are left alone (use Import for
  those); after that anything new is fetched, including shots taken while
  the camera was away.
- **Take a picture from the Mac**: with the camera on a cable (USB debugging
  on), "Take a Picture" in the sidebar or File menu (Cmd-T) fires the
  shutter, waits for the camera to finish writing the shot, brings it into
  the library and opens it. The transfer runs at USB 2 speed, so a shot
  takes about half a minute to arrive.
- **Highlight recovery in the merge**: the camera exposes its main lens a
  stop under the others, so that lens holds detail in bright areas the
  others have lost. The merge now uses it: skies, windows and lamps that
  used to go flat white keep their texture, rolled off smoothly. The merged
  DNG keeps the whole extra stop for you to place in a raw converter.
- **Real capture details**: the library is ordered by when each shot was
  taken, read from the camera's own record in the raw file, and exports
  carry it as standard metadata (date and time zone, exposure, sensitivity,
  focal length, lens, and the location when the camera had one), so they
  sort and search properly in Photos, Lightroom and the like.

**Not yet**: depth effects (refocusing, background blur), and reliable
telephoto detail at close range. Nobody in the L16 community has reproduced
Light's full fusion pipeline; this project is building its own in stages.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ installed (its toolchain compiles SwiftUI). It does not need to
  be the selected developer directory or set up beyond installing it.
- For camera import over USB: `brew install android-platform-tools` (used
  when USB debugging is enabled on the camera) and/or `brew install libmtp`
  (for the camera's file-transfer mode; macOS has no built-in MTP support).
  Wi-Fi import needs neither.

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
- **File → Import from Camera…** (⇧⌘I). By cable: plug the L16 in directly
  (not through a hub) and wake it, with either USB debugging enabled or its
  USB mode set to file transfer. By Wi-Fi: on the camera, open L16 Studio and
  turn on Wi-Fi transfer, then pick Wi-Fi in the sheet (the camera is found
  automatically on the same network, or enter the address it shows).
- Double-click a shot to open it. Left/right arrows change lens, Esc returns
  to the library, double-click the image to switch between fit and 100%.
- Adjustments, looks and export are in the inspector on the right (⌥⌘I).
  Looks are baked into JPEG, HEIC and TIFF exports; DNG stays raw (the
  merged image's DNG too).

Imported camera shots are stored in `~/Pictures/L16 Studio`. The library
index lives in `~/Library/Application Support/L16Studio`.

## The on-camera app

`camera-app/` is a small Android app that runs on the L16 itself (the camera
is an Android 6 device underneath):

- **Gallery** of the shots on the camera, with a full-screen viewer (pinch or
  double-tap to zoom, swipe between shots) and delete.
- **Editing on the camera**: Auto measures each photo (tonal range,
  mid-tone brightness, colour cast) and corrects it; six looks build on that
  (Auto, Vivid, Golden, Crisp, Film, Mono), with sliders for exposure,
  contrast, highlights, shadows, colour, warmth, fade and sharpening. Hold
  the picture to compare with the original. Saving writes a full-size copy
  next to the shot; the original and the raw file are never changed. Edits
  work on the camera's 8 MP preview, not on the raw data.
- **Wi-Fi transfer**: a switch that serves the shots on the local network, so
  L16Studio on the Mac, or any browser at the address shown, can pull them
  without a cable. It is read-only, unauthenticated and only runs while
  switched on, so use it on a network you trust.
- A button to jump to Light's own camera app, which still does the shooting.
- **An optional home screen** built for a camera: one large Camera tile, then
  Gallery (showing the latest shot), Transfer, Screen off and All apps, with
  the date, battery and free space along the top. All apps lists everything
  installed (Firefox, Settings and the rest); hold an icon for its system
  page. Nothing is replaced: the first time you press Home, Android asks
  whether to use "L16 Studio Home" or the stock one, and the "Home screen…"
  button in All apps opens the setting that switches between them.
- **Screen off and lift to wake**, for cameras whose power button no longer
  works. A button in the gallery, and a second icon in the app list, put the
  camera to sleep (long-press the button to skip straight to real sleep).
  For the first ten minutes the screen is only blacked out,
  so a tap wakes it instantly; after that it really sleeps, and picking it up
  or uncovering it wakes it (using the tilt and proximity sensors, which work
  while it sleeps; the touch panel does not). Android asks you
  to allow the screen-off part the first time (the app registers as a device
  administrator with one permission, locking the screen).

### Installing it on a camera

The easy way is the ready-made package, `L16Studio-camera-<version>.zip`,
from the [releases page](https://github.com/sunkencity999/L16Studio/releases):
unzip it and run the installer for your computer (`install.command` on a Mac,
`install.sh` on Linux, `install.bat` on Windows). It fetches Google's adb tool
if the computer doesn't have it, waits for the camera, tells you how to switch
on USB debugging (the one step that has to be done by hand, on the camera),
checks the device really is an L16, and installs and opens the app. It
installs one ordinary app: nothing is rooted or flashed, and
`install.sh --uninstall` removes it again.

To make the package yourself:

```sh
scripts/package-camera.sh     # -> build/L16Studio-camera-<version>.zip
```

The APK is signed with `camera-app/dev.keystore`, which is created on the
first build and is not in the repository. Keep it backed up: an update only
installs over an earlier copy when it is signed with the same key.

### Building it

To build and install straight from source over USB (USB debugging must be
enabled on the camera: Settings → About → tap Build number seven times, then
Developer options):

```sh
brew install openjdk@17 android-platform-tools
brew install --cask android-commandlinetools
sdkmanager "platforms;android-23" "build-tools;34.0.0"
camera-app/build.sh --install
```

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
camera-app/          The on-camera Android app (gallery, editor, Wi-Fi transfer)
deploy/              Installers and instructions for the camera package
scripts/package-camera.sh  Builds the camera package zip
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
