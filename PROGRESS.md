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

### Tools

- `swift run lriprobe <file.lri> [...]` -- CLI inspector: prints metadata,
  per-image dimensions/sensor/calibration, unpacks pixels and reports
  min/max/mean, and (for the reference camera) writes a debug preview PNG.
