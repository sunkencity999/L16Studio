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
and rendered a full 4160x3120 color image with clean, alias-free demosaicing.
(That only proved the green sites were right -- a red/blue swap also
demosaics cleanly. See the colour section below.)

**Colour accuracy -- fixed 2026-11-16.** Verified on a fresh shot against
the camera's own JPEG of the same frame, across all nine colour modules. The
"green cast" was four separate bugs, none of them in Light's calibration:

1. `unpackTenBit` (a faithful port of the reference decoder) returns the frame
   in *reversed* pixel order. That rotates the picture 180 degrees and shifts
   the Bayer phase by one in both axes. `unpackTenBitFrame` now restores
   readout order; `RawImage.unpackedSamples()` uses it.
2. The CFA table mixed two conventions. The rule is simply: `sensor_bayer_red_
   override` is the (x, y) of the red site in the 2x2 tile, in readout order
   -- (0,0)=RGGB, (1,0)=GRBG, (0,1)=GBRG, (1,1)=BGGR.
3. DNG tag numbers were off by one: the neutral went into `AsShotWhiteXY`
   (50729) and identity `AnalogBalance` into `AsShotNeutral` (50728), so every
   file said "neutral = 1,1,1". Correct tags: 50727 AnalogBalance, 50728
   AsShotNeutral, 50730 BaselineExposure. This is why `CIRAWFilter` appeared to
   ignore the neutral.
4. Light's matrices are in standard DNG form after all: `colorMatrix` is an
   XYZ->camera ColorMatrix, `forwardMatrix` a ForwardMatrix (rows sum to the
   D50 white), and `rgRatio`/`bgRatio` are R/G and B/G of a neutral under that
   illuminant (inv(ColorMatrix_D65) x (rg,1,bg) lands on D65). The DNG now
   carries the A and D65 pairs as calibration 1 and 2.

Also new: the shot's own `awb_gains` set `AsShotNeutral` (reciprocal of the
gains), and `BaselineExposure` = log2(image_gain / (module analog x digital
gain)) -- the reference module is captured at half the gain of the others.

**Still open:** mono module (A2) has no DNG path (it renders as grey in the
app), and BayerJPEG captures are unimplemented. An earlier note here said B1
came out rotated; on later shots every telephoto frame is upright, so that
was a misreading of one busy frame.

## Tools

- `swift run lriprobe <file.lri> [...]` -- CLI inspector: prints metadata,
  per-image dimensions/sensor/calibration, unpacks pixels and reports
  min/max/mean, and (for the reference camera) writes a debug preview PNG,
  a real DNG, and a `CIRAWFilter`-rendered PNG from that DNG.

## App rebuild (2026-11-16)

The original app shell (sidebar of files + per-file gallery + modal detail)
was replaced. It is now a SwiftPM executable (`Package.swift`, sources in
`L16Studio/Sources`) wrapped into a bundle by `scripts/build-app.sh`; the
XcodeGen project is gone. `xcodebuild` is not needed, only Xcode's toolchain
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build`),
because SwiftUI's macros don't ship with Command Line Tools.

- `Library.swift` -- `LibraryStore`: JSON index in Application Support, flags,
  ratings, filters. Disk imports are referenced in place.
- `Thumbnailer.swift` -- serialised preview rendering with memory + disk cache.
- `ShotSession.swift` -- one open shot: a `LensRenderer` per lens, a quick
  preview render followed by full resolution once input settles, export.
- `LRIKit/LensRenderer.swift` -- keeps the `CIRAWFilter` per lens so exposure
  and white-balance changes don't re-unpack; renders the mono module (A2) as
  linear grey.
- `CameraLink.swift` + `CameraImportView.swift` -- camera import over MTP by
  driving the libmtp CLI tools (`mtp-files`, `mtp-getfile`). The stock camera
  exposes no storage in PTP mode, so ImageCaptureCore is not an option, and
  macOS has no native MTP. Sessions opened immediately after another one
  closes can fail with "No devices"; `download` retries.
- Views: `RootView` (split view + sidebar), `LibraryGridView`, `ViewerView`
  (zoomable canvas + lens strip), `InspectorView` (info, adjust, export).

Verified by running the built app: opening a file from the command line
imports and opens it; the grid, viewer, lens strip (all ten lenses including
mono), inspector, and the Fused view (selected with the arrow key) render
correctly. Not yet exercised through the UI: camera import sheet, export
buttons, multi-selection actions. The 16-bit TIFF conversion used by fused
export was tested separately.

Gotchas hit: launching *by* opening a file created no window with
`WindowGroup` + `onOpenURL` (fixed with an app delegate), and then two windows
(fixed by using a single `Window` scene). Screenshots of the app look yellower
than the image really is because they're in the display's profile; convert to
sRGB before judging colour.

## Fusion, stage one: same-focal-length merge (2026-11-16)

`WideFusion.fuse` (`LRIKit/Sources/LRIKit/Fusion*.swift`) merges every colour
lens that shares the reference lens's focal length. On a 35 mm shot that is
A1 (reference) + A3, A4, A5. About 1.7 s per shot in a release build.

How a 35 mm shot is laid out (seen on four test shots): the five A modules
(28 mm) each see the whole scene from a few centimetres apart and are focused
at *different distances*; the five B modules (70 mm) tile the middle of the
scene. The camera's own JPEG is the 35 mm crop.

Pipeline:
1. Each lens is rendered through `CIRAWFilter` to linear float RGB
   (`LensRenderer.renderLinear`).
2. `TileAligner`: coarse-to-fine block matching on a sqrt-luma pyramid.
   Exhaustive +/-16 search at the coarsest level (about +/-512 px at full
   size), +/-2 refinement per level, 32 px tiles at full resolution,
   mean-removed SAD, parabola sub-pixel fit. Shifts between A modules reach
   700+ px on close-ups.
3. Confidence-weighted diffusion: tiles with no texture (judged against the
   image's own noise floor) take their displacement from textured neighbours.
4. `TileField.warp`: bilinear-interpolated displacements, Catmull-Rom sampling.
5. `TileField.reliability`: distrust wherever the field *bends* (second
   difference > ~2.5 px between tiles).
6. `DetailMerger`: low-frequency tone match to the reference, then a two-band
   merge. Weights = consistency with the reference's base band x local detail
   energy (squared for the detail band), so a defocused lens can't soften a
   sharp one and equal-sharpness areas average (noise reduction).

What went wrong on the way, so it isn't repeated:
- Apple's `VNGenerateOpticalFlowRequest` is not usable for registration: on a
  synthetic 12 px / 5 px shift it reported 5.3 / 2.35 (and 6.5 / 2.6 at
  `.veryHigh`), uniformly. Convention, for the record: handler image A,
  targeted image B, flow = where A's content went in B, +y down.
- Without step 5, warped creases around out-of-focus foreground objects were
  taken for sharp detail and dominated the merge.
- Measuring field roughness by *first* differences rejected whole receding
  surfaces (a desk: the shift legitimately changes ~5 px per tile). Second
  differences fixed that. Without step 3, plain walls were rejected because
  their tiles matched noise.

Results (share of the frame where each extra lens contributed): room shot
61-69%, near-to-far shot 35-45%, keyboard close-up 20-30%. Checked at 100%
against the single reference lens: clearly lower noise, same detail, no
ghosting or creases in the regions inspected. Not measured numerically.

Open:
- Exposure: `baselineExposure` now includes exposure time (modules in one
  shot differ in both gain and time). On shot 3 that renders A1 about a stop
  brighter than the camera's JPEG; the camera may deliberately underexpose
  the reference. Unresolved which is "right".
- Next stage: bring the B (70 mm) tiles in for resolution, and output the
  35 mm crop the camera intends. That needs cross-scale registration; the
  geometric calibration in the file should give the starting transform.
- Memory: the app reached ~3.4 GB RSS after a fusion.
- Mono module (A2) is not merged yet; it should help luminance noise.
- Shot 1 looked as if B1 were rotated relative to the other telephoto frames;
  on shots 2-4 every telephoto frame is upright, so that was a misreading.

## Fusion, stage two: telephoto detail (2026-11-16)

`TeleFusion.fuse` (`FusionTele.swift`) builds the picture at the shot's focal
length: the stage-one wide merge, centre-cropped by wide/shot focal length
(28/35 = 0.8, i.e. 3328 x 2496, the same size as the camera's own JPEG) and
enlarged by `scale` (default = telephoto magnification 70/28 = 2.5, giving
8320 x 6240 = 52 MP), with each telephoto frame merged in. About 7.5 s.

Per telephoto frame:
1. `TelePlacement.locate`: normalised cross-correlation of the telephoto luma
   (shrunk by 16 x 2.5) over the wide luma (shrunk by 16), exhaustive, then
   refined at 1/8. Only needs to land within the tile aligner's reach.
2. `TelePlacement.paste`: the telephoto luma shrunk to wide scale, gain-matched
   and pasted into a copy of the wide luma; `TileAligner` then aligns it at
   wide resolution, exactly as in stage one.
3. `Resampler.warpTele`: for each output pixel, wide position -> + tile
   displacement -> telephoto position (x magnification), bicubic sample.
   `valid` = footprint x field reliability x a feather to the frame's edge.
4. `DetailMerger` with the enlarged wide image as reference and
   `bandSigma = 1.6 x scale`: the telephoto frame wins the detail band wherever
   it is sharper than the enlarged wide image and agrees with it in the base.

Results:
- Room shot (far scene): placements score 0.72-0.94, each telephoto frame
  contributes detail over 8-17% of the output; label text and edges are
  visibly sharper than the wide merge at matching crops.
- Close-range shots (keyboard, desk, gadget): placement scores 0.41-0.80 and
  contributions of 0-6% (one frame 11%). The result is clean but mostly equal
  to the enlarged wide merge. Likely causes, untested: placement by a single
  global position can't describe a telephoto frame whose content shifts a lot
  with depth, and the 10% base-band tolerance rejects frames with different
  focus. This is the main thing to improve.

Costs: about 10.8 GB resident in the app after a 52 MP run (planes are 208 MB
each and the merger holds a dozen). The app defaults to the wide merge below
24 GB of RAM. Alignment precision is limited to the wide grid's sub-pixel fit
(roughly 0.25-0.5 telephoto pixels); a refinement pass at telephoto scale
would sharpen the result further.

## Fusion refinements (2026-11-16, later)

- **Telephoto frames add detail only** (`DetailMerger.add(detailOnly:)`). When
  they also shifted the base band, their borders showed as steps on plain
  surfaces. Their agreement tolerance is 0.04 (wide merge: 0.10), which
  removed thin stray lines of uncorroborated telephoto detail.
- **Close range is still the weak spot.** `L16_FUSION_DEBUG=<dir>` dumps each
  telephoto frame pasted at its placement plus its trust grid. On the
  keyboard shot the alignment is trusted only on key tops, in a checkerboard:
  every gap between keys is a depth step. 16 px tiles (`L16_FUSION_TILE=16`)
  looked like a big gain until the bend tolerance was scaled to the tile size
  (`bendTolerance`), after which they accept about the same area as 32 px
  tiles; the apparent gain was the looser tolerance letting creases back in.
  A real improvement needs a different model (per-pixel flow or depth planes
  from the geometric calibration), not smaller tiles.
- **Memory**: 52 MP peak cut from 10.4 GB to 8.1 GB (in-place tone matching,
  1/16-size reference for tone, in-place finish, no-copy CGImage). Output
  byte-identical. The per-frame working set is what remains.
- **Mono lens (A2)**: `DNGWriter` writes it as a LinearRaw DNG, which
  `CIRAWFilter` accepts, so `LensRenderer` now uses one path for colour and
  mono (the hand-rolled grey render is gone) and mono exports as DNG. In the
  wide merge it is aligned like any lens and added detail-only; tone matching
  scales each channel to the reference's local colour, so it cannot
  desaturate. It needed -0.7 EV (the unfiltered sensor collects about 1.65x
  the light of a colour module's green channel); with that, it is accepted
  over 63% / 22% / 35% of the room / keyboard / near-to-far shots. Visible
  effect is small: slightly cleaner shadows, no artifacts seen.

## Camera link and the on-camera app (2026-11-16)

**Import transports** (`CameraLink.swift`), all verified end to end through
the import sheet on real shots, each download compared byte for byte:
- adb (`adb shell ls -l /sdcard/DCIM/Camera`, `adb pull`), preferred when a
  device is attached and authorised. About 35 s per 160 MB shot.
- MTP via libmtp, the fallback (see the app rebuild notes).
- Wi-Fi: HTTP to the on-camera app, found by Bonjour (`_l16studio._tcp`) or by
  address. Tested through `adb forward tcp:8016 tcp:8016` because the Mac and
  camera were on different networks; **not yet tested over real Wi-Fi**, and
  Bonjour discovery is untested for the same reason.

**On-camera app** (`camera-app/`, package `dev.sunkencity.l16studio`): pure
Java, no Gradle, no dependencies; `build.sh` runs aapt2, javac, d8, zipalign
and apksigner and produces a 48 KB APK. targetSdk 22 so storage permission is
granted at install. Activities are landscape (the camera's 1080x1920 panel is
used sideways). Shots live in `/sdcard/DCIM/Camera` as `L16_NNNNN.lri` plus
an in-camera `L16_NNNNN.jpg` preview (3328x2496), which is what the gallery
and viewer show. `TransferService` is a foreground service with a hand-written
HTTP server on port 8016 (GET/HEAD only, Range support, shot names restricted
to `[A-Za-z0-9_-]+` so nothing outside the camera folder is reachable).

Driving the camera from the Mac, useful for testing: `adb shell input keyevent
KEYCODE_FOCUS` then `KEYCODE_CAMERA` takes a shot in Light's camera app;
`adb exec-out screencap -p` grabs the screen (1920x1080).

**Stock services were not disabled.** `pm disable-user` from the adb shell is
refused for system packages on this build ("Permission Denial ... package uid
1000"). Doing it needs root for one boot. See `docs/camera-package-survey.md`
for the candidates.

## On-camera editor (2026-11-16)

`camera-app` gained `EditActivity` and `Look`. Reached from the viewer's Edit
button.

- `Look.analyse` measures a 320 px copy: black/white points at the 0.4 and
  99.6 percentiles (capped so a deliberately dark or light picture isn't
  forced to full range), a gamma that moves the median 60% of the way to
  0.46, and a colour-cast correction from near-neutral mid-tone pixels only,
  limited to +/-12% per channel and skipped if under 5% of pixels qualify.
- `Look.forStyle` layers a preset on those measurements; every style except
  Original starts from the Auto correction.
- `Look.render` is three RenderScript intrinsic passes: a per-channel LUT
  (levels, gain, gamma, shadow/highlight bumps, contrast S-curve, split
  toning, fade), a luma-preserving saturation matrix, and a 3x3 sharpen.
  Framework RenderScript only, so no build step beyond javac.
- The preview is 1600 px wide; saving re-renders the full 3328x2496 preview
  JPEG and writes `L16_NNNNN_edit_<Style>.jpg` (then `_2`, ...) at quality 95.
  The gallery lists it as its own entry labelled with the style.

Checked on the camera: every style renders, the sliders update live, and a
saved Vivid copy was pulled back and confirmed full size. Not checked: how it
compares with the stock gallery's own editing (I have not looked at what that
offers), behaviour on very dark or very bright photos, and hold-to-compare.
Limits: tone shaping is a global curve (no local shadow recovery), and it
edits the camera's 8-bit preview, not the raw file.

## Looks in the Mac app (2026-11-16)

`LRIKit/Look.swift` ports the on-camera editor's maths: `LookMeasurement`
(the Auto analysis), `LookSettings` (style presets + sliders, stored in
`RenderAdjustments.look`), and `LookRenderer`, which bakes the per-channel
tone curve and the saturation change into a 48^3 `CIColorCubeWithColorSpace`
(Display P3) followed by `CIUnsharpMask`.

- Single lenses: `LensRenderer.render` applies the look after the raw
  development. The measurement is taken once, from the as-shot rendering, so
  later exposure or white-balance changes aren't undone by Auto.
- Fusion merges developed frames without the look and the look is applied to
  the result (`LookRenderer.apply(_:to:)`, measured from that image). The app
  caches the merge, so changing the look doesn't re-run it.
- Inspector: a Look section with style buttons and "Fine-tune" sliders.

Bugs found while testing, both fixed:
- Measuring by temporarily changing the `CIRAWFilter`'s `scaleFactor` and
  setting it back left later full-size renders small (a thumbnail-sized image
  in the middle of the canvas). The measurement now shrinks the developed
  image with a plain transform and leaves the filter alone.
- The colour-cast estimate treated pale green walls as near-neutral and
  "corrected" whites to lavender. It now counts only nearly grey pixels
  (max-min < 26 of 255), needs 8% of the frame, moves half-way, is capped at
  +/-8%, and the channel gains ease off towards white. Same change made in
  `camera-app/.../Look.java`.

Checked: all seven styles on the fused room shot from the command line
(`lriprobe --fuse-tele --look=vivid`), and Vivid in the app on a single lens
and on the 52 MP fusion. Not checked: clicking the style buttons and sliders
in the app (the look was set through the library file for the test), and
exports with a look applied.

## Deployment package for other cameras (2026-11-16)

`scripts/package-camera.sh` builds `build/L16Studio-camera-<version>.zip`
(about 60 KB): the APK, `deploy/install.sh` (macOS/Linux), `install.command`
(double-click on a Mac), `install.ps1` + `install.bat` (Windows), a plain-text
README and the licence.

The installer uses the computer's adb or downloads Google's platform-tools
into the package folder, waits for the camera (with instructions for "no
device" and "unauthorized"), prefers a device whose `ro.product.model` is
`L16` and asks before touching anything else, installs with `adb install -r`,
and opens the app. `--uninstall`, `--replace` (for a copy signed with another
key), `--yes`.

A stock L16 cannot be set up without one manual step: USB debugging has to be
enabled on the camera itself. Nothing in the package needs root or touches the
camera's system.

Tested on macOS against the real camera: fresh install from an unpacked zip
with no adb on PATH (it downloaded platform-tools), uninstall, repeat
uninstall, install over an existing copy, bad option; and with a stub adb:
no device, unauthorized, non-L16 device declined. Not tested: Linux, the
Windows scripts (written but never run), the `--replace` path, and a camera
that has never had USB debugging enabled (the menu wording in the
instructions is what worked on this unit).

The APK is signed with `camera-app/dev.keystore` (gitignored, generated on
first build, password in `build.sh`). It only exists on the build machine;
losing it means later versions cannot update earlier installs in place.

## Dead power button: Screen off and lift to wake (2026-11-16)

On the development camera the power button (the small one beside the shutter)
sends nothing: `qpnp_kpdpwr_status` in `/proc/interrupts` stays at 0 through
repeated presses and across a reboot, and `getevent` shows no `KEY_POWER`.
An injected `input keyevent KEYCODE_POWER` sleeps and wakes the camera, so the
fault is below Android. Probably hardware; possibly older than this project.

Things learned about the L16's controls while chasing it:
- Physical keys: shutter half press (`KEY_CAMERA_FOCUS`, gpio `cam_focus`),
  shutter full press (key 766 -> CAMERA, gpio `cam_snapshot`), power
  (`qpnp_pon` KEY_POWER). The PMIC RESIN line ("volume down" to the
  bootloader) fires together with the full shutter press.
- The "volume" area is `elan-touchscreen`, a 768 x 1 touch strip: Light's
  zoom slider.
- `getevent` takes one device at most; with none it reads them all.

`camera-app` 0.2.0 works around it:
- `SleepActivity` ("Screen off" launcher entry + gallery button) calls
  `DevicePolicyManager.lockNow()`. The app is a device admin with only
  `force-lock`. The user must approve Android's prompt; granting it with
  `dpm set-active-admin` over adb was (rightly) not allowed here.
- `WakeService` (foreground, restarted on boot while the admin is active)
  registers the wake-up tilt detector (type 22, hidden constant at API 23)
  and wake-up proximity sensor while the screen is off, and turns the screen
  on with a `SCREEN_BRIGHT_WAKE_LOCK | ACQUIRE_CAUSES_WAKEUP` lock on a tilt
  (unless covered) or on being uncovered. 1.5 s settle time after screen off.
- Nothing wakes the stock camera otherwise except USB power: the shutter keys
  are not wake keys, and `double_tap_to_wake=1` in settings has no effect.

Verified: screen off works (user confirmed); with the screen off both sensors
show as active for `WakeService` in `dumpsys sensorservice`. Not yet verified
at the time of writing: that tilting or uncovering actually wakes it.

A stronger fix would make the shutter half press a wake key via a key-layout
override in `/data/system/devices/keylayout/` (`key 528 FOCUS WAKE`), which
needs root for one boot; not done.

### Tap to wake, and the editor's compare bug (2026-11-16)

- **Tap to wake** cannot work in real sleep: there are no wake-gesture nodes
  for the `dsx` (screen) or `touchpad` (zoom strip) controllers and
  `dumpsys power` reports `mDoubleTapWakeEnabled=false`. So Screen off now
  starts with `NapActivity`: black, `screenBrightness = 0` (clamped by the
  system to its minimum, 10/255), `FLAG_KEEP_SCREEN_ON`, any touch or key
  finishes it. After `DEFAULT_SECONDS` (600; the owner chose ten minutes, valuing instant readiness over battery) it calls `SleepActivity.sleepNow`
  for real sleep. `--ei nap_seconds N` on the SleepActivity intent shortens it
  for testing. Verified over adb: nap at brightness 10, a tap returns to the
  previous screen with brightness restored, a 6 s timer ends in
  `Dozing` / display OFF. The user confirmed lift to wake works.
- **Hold to compare did nothing** because `Allocation.createFromBitmap(rs,
  bitmap)` shares the bitmap's memory and the render passes wrote back into
  it: the working "original" became the edited picture, and every re-render
  stacked the look on the previous one. Fixed with an explicit
  `USAGE_SCRIPT` (private copy). Verified with screenshots before, during and
  after a long press, and after switching looks away and back.
- **Browser**: the camera's WebView is Chromium 52 and its browser Chromium
  54 (2016), security patch level 2017-06, no Play Store. A browser written
  on that WebView would inherit its limits. Current Firefox needs Android 8;
  Firefox 143 (September 2025) is the last release for Android 5-7 and brings
  its own engine and certificate store. Installed on the development camera
  at the owner's request: `fenix-143.0.4.multi.android-arm64-v8a.apk` from
  archive.mozilla.org, signed by Mozilla Release Engineering (certificate
  SHA-256 a78b62a5...319b04), minSdk 21. It starts without crashing; page
  loading was not checked because the camera was PIN-locked at the time.
- **Lift to wake must always be running** (0.2.1). An unplugged test failed
  because `adb install -r` had stopped `WakeService` and it was only started
  by Screen off or at boot, while the screen had gone off by the lock
  screen's own 10 s timeout. It now also starts on `MY_PACKAGE_REPLACED`,
  when the device-admin permission is enabled, and when the gallery opens.
  Verified: after an update the service is back without opening the app.
  Still to confirm: that it wakes the camera when unplugged and suspended
  (on USB the processor never fully suspends, so plugged-in tests don't
  prove this; if it fails, hold a partial wake lock while armed).
- Long-pressing Screen off skips the nap and sleeps at once.
- The camera did not power off when unplugged (uptime was continuous, and
  the battery reads healthy: 100%, 4,269 mAh full charge). The cold-start
  test of the power button therefore hasn't happened yet.
- **Lift to wake made more sensitive** (0.2.2). The owner confirmed it works
  unplugged but needed "a fair bit" of wiggling: the tilt detector wants a
  35-degree change held for two seconds. `WakeService` now also registers the
  wake-up accelerometer (100 ms samples, delivered in 600 ms batches so the
  processor can doze between them) and wakes on a turn of more than 12
  degrees from the resting gravity vector, or on two consecutive readings
  more than 1.3 m/s^2 away from 1 g. Covered proximity still suppresses
  everything and moves the resting reference along. Each wake logs its
  reason under the `L16Wake` logcat tag. Verified over adb: the sensor is
  registered while asleep and the camera does not wake itself lying still.
  Not yet known: how it feels in the hand, false wakes when carried
  uncovered, and the standby battery cost of the batched accelerometer.

### Power button: comparison with a second, working L16 (2026-11-17)

Read-only probe of a second camera (LightOS 1.3.0.4, kernel
3.18.20-perf-g6ec34d3) beside the development one (1.3.5.1,
3.18.20-perf-g32d1d1c):

- The power-key device-tree configuration is byte-identical on both:
  `pon_1` KPDPWR, key code 116, s1 10256 ms + s2 2000 ms -> warm reset;
  `pon_2` RESIN, no key code; `pon_3` KPDPWR+RESIN, s1 6720 ms + s2 2000 ms,
  s2-type 7 (hard reset), with bark. So holding power ~12 s restarts the
  camera and power + full shutter ~9 s forces it off, which matches what was
  seen during the repair.
- On the working camera four presses gave `qpnp_kpdpwr_status` = 8 and
  "Going to sleep due to power button" in the log within two minutes of boot.
- On the development camera the same counter stayed at 0 through about ten
  presses and a reboot, then read 2 hours later: one press got through.

Same software path, same configuration, one unit intermittent: the fault is
that unit's switch or its connection, not software. The Screen off / tap to
wake / lift to wake controls remain the workaround. Nothing was installed or
changed on the second camera.

### Second camera updated and set up (2026-11-17)

The second L16 went from LightOS 1.3.0.4 to 1.3.5.1 by Light's own route:
the update zip copied to the root of internal storage (`adb push`, md5
checked on the camera), then a restart and the on-camera update prompt. Its
60 files were backed up and size-verified first; an interrupted `adb pull` of
the folder was resumed file by file. Afterwards: build `00WW_1_351`, verified
boot still green, all shots present, the zip consumed. The released
`L16Studio-camera-0.2.2.zip` installer then installed the app in one run:
the first use of the package on a camera other than the development one.
The Mac's USB port did not charge that camera while it was awake and
transferring (42% for over half an hour); it needed a wall charger to reach
the half charge Light asks for.

### Capture details and a home screen (2026-11-17)

- The raw file's `image_time_stamp` is local wall-clock time and `tz_offset`
  is minutes from UTC (-480 on shots taken in California in November; the
  times match the files' own dates). The library now sorts by it, and index
  entries written before this are refreshed once on launch (`hasCameraTime`).
- GPS fields are present but NaN when the camera had no fix; none of the
  shots so far has a location, so the GPS export path is covered only by a
  unit test with made-up coordinates.
- Exports carry EXIF/TIFF details (date with offset, exposure, sensitivity,
  35mm focal length, lens, make and model); DNGs carry DateTime and
  Software. `MetadataTests` exports a real shot as JPEG, HEIC and DNG and
  reads the values back. The fused export path uses the same dictionary but
  was not exercised by a test.
- Camera app 0.3.0 adds `HomeActivity` (HOME category) and `AppsActivity`.
  Checked on the second camera by starting the activity directly, without
  making it the default: each tile opens the right screen, Firefox launches
  from All apps, Back on the home screen does nothing. Not yet checked:
  choosing it in Android's home-screen prompt and living with it across a
  restart.

### Automatic import over Wi-Fi (2026-11-17)

- First real test of the wireless path, with the second camera and the Mac
  on the same network: the listing answers at the camera's address, Bonjour
  discovery finds "Light L16", and a download completes at full size.
- `AutoSync` (Mac) polls a discovered camera every 12 s. It keeps a record
  per camera (`autoSyncKnownShots` in the app's defaults, keyed by the `id`
  the camera app now reports: the last six characters of its serial). First
  meeting records what is there and downloads nothing; later passes fetch
  whatever is not in the record. Checked: 31 existing shots recorded and
  none fetched, then a shot taken on the camera was in the library within
  about ten seconds with the right capture time.
- Two cameras number their shots alike. Auto-import puts a clashing name in
  a "Camera <id>" subfolder. The manual import sheet does not: importing
  L16_00001 from a second camera there would replace the first camera's
  file of that name. Fixed straight after: a same-name file of a different
  size is kept and the new one goes into "Camera 2" (not exercised with a
  real clash; raw sizes differ between the two cameras seen so far, but two
  shots of equal size and name would still be treated as the same file).
- The finder now drops a camera when its advertisement goes away.
- Left as found after the test: the camera's Wi-Fi transfer off, the Mac's
  switch off. The test shot (L16_00032) is still on the second camera and
  in the Mac library.

### Taking a picture from the Mac (2026-11-17)

`CameraLink.capture()` wakes the camera over adb, refuses if the lock screen
is showing, brings Light's camera app forward, sends KEYCODE_CAMERA and waits
for a new `.lri` whose size has stopped changing. Checked once on the second
camera from the app's File menu: L16_00033 was taken, pulled at full size
(about 35 s at roughly 4.5 MB/s) and added to the library index. Not
confirmed by eye: that the viewer then opened on it (the Mac's display was
not capturable at the time). It cannot work over Wi-Fi: an ordinary app on
the camera is not allowed to press keys. Two test shots (L16_00032 and
L16_00033) are on the second camera and in the Mac library as a result of
this and the auto-import test.

### Merged image as a raw DNG (2026-11-17)

- `renderLinear(sceneLinear: true)` sets `CIRAWFilter.boostAmount` to 0 for
  the render, so the merge works on values without Core Image's tone curve.
  Lens acceptance in both merges is within a few points of the normal run
  (wide 25-36% vs 20-30% on shot 3; telephoto similar on shot 4), so the
  alignment thresholds hold for the flatter data.
- `DNGWriter.writeLinear` writes LinearRaw, 3 x 16-bit, ColorMatrix1 =
  XYZ(D65) -> linear Display P3, neutral 1:1:1, two stops of headroom above
  nominal white with BaselineExposure +2. Rendered back through ImageIO it
  matches the normal merge in colour and brightness. Not yet opened in
  Lightroom or Capture One.
- Sizes: 77 MB for the 13 MP wide merge, 311 MB for the 52 MP full merge
  (uncompressed). The full merge peaks at about 10 GB of memory, most of it
  the merge itself.
- `lriprobe --fuse-dng`, and `--fuse-tele --dng`.

### Highlight recovery (2026-11-17)

- Every shot looked at has the reference module (A1) at half the analog
  gain of the rest. Development lifts it a stop to match, and CIRAWFilter
  then clips what goes past white: merged values topped out at 1.0-1.3.
- `renderLinear` now develops such a module a second time without the lift
  and blends that in above 0.72 linear. For display it is folded under
  white with a shoulder applied to the brightest channel (the others follow
  in proportion); with `sceneLinear` it is left above 1.0. The ratio between
  the two developments is measured just below the knee, because the tone
  curve makes it differ from the nominal 2x.
- Shot 2 (office ceiling): tile lines and light fixtures that were flat
  white are back, smooth gradient, no fringing at 1:1. Merged DNG values now
  reach 2.0, with 4.4% of pixels above 1.0. The other lenses are clipped in
  those areas and are rejected there by the existing agreement test.
- Side effect: unclipped near-whites between 0.72 and 1.0 come out a little
  darker than before (the shoulder starts there).
- Only the merge has this. A single lens shown or exported on its own still
  clips. `L16_NO_HIGHLIGHTS=1` switches it off for comparison.

### Monochrome-lens merge (2026-11-17)

- `WideFusion.fuse(monochrome: true)` uses the monochrome module (A2 on the
  shots seen) as the base, reduces each same-view colour frame to grey,
  aligns and merges them, and returns grey in all three channels.
- Shot 3 at 1:1 against the colour merge converted to grey: clearly less
  grain on plain surfaces, lettering as sharp or sharper. Colour lenses were
  accepted over 8-32% of the frame (a close subject, so parallax is large).
- Tonal rendering is the sensor's own: a red key comes out dark.
- The base is a module at full gain, so it has no highlight headroom of its
  own; recovered highlights come only from A1 where it is accepted.
- In the app it is a third choice ("Mono lens") in the fusion picker, shown
  when the shot has a monochrome frame, and it exports like the other
  merges. The picker and export were built but not clicked through.
- `lriprobe --fuse --mono`.

### Depth from parallax, and background blur (2026-11-17)

**Geometry.** Every file carries factory calibration per module: intrinsics
at two focus distances and, for the wide and glued-mirror modules, rotation
and translation relative to A1 (`LRIFile.geometry`). The A modules sit
24-43 mm from A1, fx about 3375 px. Checked against the merge's alignment
fields: with the image in the calibration's own orientation (no flips), the
shift of each lens runs along its predicted baseline (median off-axis error
1-6 px) and on a close subject the lenses agree on distance to 1-2%. On a
far scene they disagree by 20-35% until a constant per-lens correction of a
few pixels is fitted (calibration drift); that fit is part of the solve,
with its shared component removed so scale stays tied to calibration.

**Depth map** (`DepthEstimator`, 1/8 scale, inverse millimetres):
1. Tile fields -> per-lens corrections and the range of distances present.
2. Dense search: for each cell and candidate distance, sample every other
   lens where geometry says the point would be; cost is the difference in
   local contrast, averaged over the better half of the lenses.
3. Confidence = clear winner x texture x not blown out; unconfident cells
   are filled from confident ones of similar tone.
A first version built only from the tile fields measured 34% of the keyboard
shot and guessed half the keyboard wrong (the tile aligner fails on shifts of
300-500 px). The dense search measures 67% and gets the whole keyboard as one
receding surface, 0.2-1 m, which matches the scene.

**Background blur** (`Refocus`): blur circle = focal length x aperture x
difference in inverse distance; seven blur levels, each built only from
pixels that are themselves about that blurry so a sharp subject doesn't
smear into what is behind it. 0.4 s at 13 MP.

**What it looks like.** Keyboard shot, focus on the middle rows, 18 mm:
convincing, with the keyboard sharp in a band and smooth fall-off both
ways. Office shot (2-7 m, blank green walls, blown ceiling): the near chair
blurs correctly, but there are still patches of wrong distance on walls and
ceiling.

**Limits.** Wide and mono merges only (the full merge has a different
canvas). Depth edges are only as fine as the 1/8-scale map. Nothing is done
about hair-like detail. In the app (Depth section: switch, aperture slider,
click to focus, blur in exports) the controls were built but not clicked
through: capturing the app window did not work in this session.

`lriprobe --fuse --refocus=x,y[,aperture]` writes `_depth.png` and
`_refocus.jpg`; `--geometry` prints the calibration; `L16_FUSION_DUMP=dir`
writes the tile fields.
