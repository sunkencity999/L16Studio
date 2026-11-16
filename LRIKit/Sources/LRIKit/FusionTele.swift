import Foundation
import CoreGraphics
import ImageIO

/// What the full (wide + telephoto) fusion did.
public struct TeleFusionReport: Sendable {
    public struct Tile: Sendable {
        public let camera: CameraID
        /// Where the telephoto frame's top-left corner sits in the wide
        /// reference, in wide-frame pixels.
        public let origin: CGPoint
        /// Match quality of that placement, -1...1 (normalised correlation).
        public let placementScore: Float
        /// Share of the frame's footprint where the alignment was trusted
        /// (before the merge's own consistency check).
        public let aligned: Float
        /// Share of the output picture this lens contributed detail to.
        public let coverage: Float
    }
    public let wide: FusionReport
    public let tiles: [Tile]
    public let outputSize: CGSize
    /// Output pixels per wide-lens pixel.
    public let scale: Float
    public let seconds: Double
}

/// Stage two of lens fusion: the wide lenses give the whole picture, the
/// telephoto lenses add finer detail where they look.
///
/// At an in-between zoom (say 35 mm) the camera fires its 28 mm lenses,
/// which each see everything, and its 70 mm lenses, which each see a part of
/// the scene at 2.5x the detail. This builds the picture the camera intended:
/// the wide merge (stage one) cropped to the shot's focal length and
/// enlarged, with each telephoto frame located in it, aligned tile by tile,
/// and merged in. The merge is the same detail-aware one as stage one, so the
/// telephoto frames win wherever they are sharper than the enlarged wide
/// image and are ignored wherever they don't line up.
public enum TeleFusion {
    /// True when the shot has telephoto frames this can use.
    public static func canFuse(_ file: LRIFile) -> Bool {
        guard let plan = try? Plan(file: file) else { return false }
        return !plan.tele.isEmpty
    }

    struct Plan {
        let reference: RawImage
        let tele: [RawImage]
        /// Telephoto pixels per wide pixel (70/28 = 2.5, 150/70 = 2.14).
        let magnification: Float
        /// Fraction of the wide frame kept for the shot's focal length.
        let crop: Float

        init(file: LRIFile) throws {
            guard let reference = file.referenceImage, reference.cfaPattern != nil else { throw FusionError.noReference }
            self.reference = reference
            let wideFocal = reference.camera.focalLength
            let longer = Set(file.images.map(\.camera.focalLength).filter { $0 > wideFocal }).min()
            tele = file.images.filter {
                $0.cfaPattern != nil && $0.camera.focalLength == longer
                    && $0.width == reference.width && $0.height == reference.height
            }
            magnification = Float(longer ?? wideFocal) / Float(wideFocal)
            let shotFocal = Float(file.metadata.focalLength ?? Int32(wideFocal))
            crop = min(1, max(1 / magnification, Float(wideFocal) / max(shotFocal, 1)))
        }
    }

    /// - Parameter scale: output pixels per wide-lens pixel. `nil` uses the
    ///   telephoto magnification, i.e. the telephoto frames at native detail.
    public static func fuse(
        file: LRIFile,
        adjustments: RenderAdjustments = .none,
        scale requestedScale: Float? = nil,
        progress: WideFusion.Progress? = nil
    ) throws -> (image: CGImage, report: TeleFusionReport) {
        let start = Date()
        let plan = try Plan(file: file)
        guard !plan.tele.isEmpty else { throw FusionError.nothingToMerge }
        let scale = min(plan.magnification, max(1, requestedScale ?? plan.magnification))

        // Stage one: the merged wide image, on the reference lens's grid.
        let (wide, wideReport) = try WideFusion.fusePlanes(file: file, adjustments: adjustments) { message, fraction in
            progress?(message, fraction * 0.25)
        }
        let wideLuma = wide.alignmentLuma()

        // Output canvas: the centre crop for the shot's focal length, enlarged.
        let cropW = Float(wide.width) * plan.crop, cropH = Float(wide.height) * plan.crop
        let cropX = (Float(wide.width) - cropW) / 2, cropY = (Float(wide.height) - cropH) / 2
        let outW = Int((cropW * scale).rounded()) & ~1, outH = Int((cropH * scale).rounded()) & ~1
        let canvas = Resampler.enlarge(wide, originX: cropX, originY: cropY, scale: scale, width: outW, height: outH)

        // The enlarged wide image carries nothing finer than about `scale`
        // pixels, so that is where "base" ends and "detail" begins.
        // The tolerance is tighter than in the wide merge: a telephoto frame
        // only adds detail, so a sliver of it that the wide image doesn't
        // corroborate shows up as a stray line on a plain surface.
        let tolerance = ProcessInfo.processInfo.environment["L16_FUSION_TELE_TOL"].flatMap(Float.init) ?? 0.04
        var merger = DetailMerger(reference: canvas, bandSigma: max(2, 1.6 * scale), ghostTolerance: tolerance)

        var tiles: [TeleFusionReport.Tile] = []
        for (index, lens) in plan.tele.enumerated() {
            let fraction = 0.25 + 0.7 * Double(index) / Double(plan.tele.count)
            progress?("Placing \(lens.camera.label)", fraction)
            let source = try LensRenderer(image: lens, file: file).renderLinear(adjustments)
            let teleLuma = source.alignmentLuma()

            // 1. Where in the wide frame does this telephoto frame sit?
            let placement = TelePlacement.locate(tele: teleLuma, in: wideLuma, magnification: plan.magnification)

            // 2. Fine alignment at wide resolution: the telephoto frame shrunk
            //    to wide scale and pasted at its placement, then tile-matched.
            let (pasted, footprint) = TelePlacement.paste(tele: teleLuma, into: wideLuma, at: placement, magnification: plan.magnification)
            let field = TileAligner.align(reference: wideLuma, target: pasted).smoothed()
            var trust = field.reliabilityGrid()
            var inside: Float = 0, trusted: Float = 0
            for i in 0..<trust.data.count {
                trust.data[i] *= footprint.data[i]
                inside += footprint.data[i]; trusted += trust.data[i]
            }
            if let dir = ProcessInfo.processInfo.environment["L16_FUSION_DEBUG"] {
                // Diagnostic dumps: the pasted placement and the trust grid.
                FusionDebug.write(pasted, to: "\(dir)/\(lens.camera.label)_pasted.png", scaleDown: 4)
                FusionDebug.write(trust, to: "\(dir)/\(lens.camera.label)_trust.png", scaleDown: 1)
                if index == 0 { FusionDebug.write(wideLuma, to: "\(dir)/wide.png", scaleDown: 4) }
            }

            // 3. Resample the full-resolution telephoto frame onto the canvas.
            progress?("Merging \(lens.camera.label)", fraction + 0.35 / Double(plan.tele.count))
            var (warped, valid) = Resampler.warpTele(
                source, onto: canvas, field: field, trust: trust,
                placement: placement, magnification: plan.magnification,
                cropX: cropX, cropY: cropY, scale: scale)
            let coverage = merger.add(&warped, valid: valid, detailOnly: true)
            tiles.append(.init(
                camera: lens.camera,
                origin: CGPoint(x: CGFloat(placement.x), y: CGFloat(placement.y)),
                placementScore: placement.score,
                aligned: inside > 0 ? trusted / inside : 0,
                coverage: coverage))
        }

        progress?("Finishing", 0.97)
        guard let image = merger.result().makeCGImage() else { throw ImageRendererError.renderFailed }
        progress?("Done", 1)
        return (image, TeleFusionReport(
            wide: wideReport, tiles: tiles,
            outputSize: CGSize(width: outW, height: outH), scale: scale,
            seconds: Date().timeIntervalSince(start)))
    }
}

/// Finds a telephoto frame inside the wide frame.
enum TelePlacement {
    struct Location {
        /// Top-left of the telephoto frame in wide-frame pixels.
        var x: Float
        var y: Float
        var score: Float
    }

    /// Exhaustive normalised cross-correlation at 1/16 of wide resolution,
    /// then a refinement at 1/8. The tile aligner absorbs what is left (it
    /// searches about +/-500 wide pixels), so this only has to be roughly right.
    static func locate(tele: Plane, in wide: Plane, magnification: Float) -> Location {
        func search(wideFactor: Int, around: (Int, Int)?, radius: Int) -> (Int, Int, Float) {
            let w = wide.downsampled(by: wideFactor)
            let teleFactor = Int((Float(wideFactor) * magnification).rounded())
            let t = tele.downsampled(by: teleFactor)
            // Zero-mean, unit-variance template.
            let n = Float(t.data.count)
            let mean = t.data.reduce(0, +) / n
            var tpl = t.data.map { $0 - mean }
            let norm = (tpl.reduce(0) { $0 + $1 * $1 }).squareRoot()
            if norm > 0 { for i in tpl.indices { tpl[i] /= norm } }

            // The telephoto frame may hang partly off the wide frame; require
            // most of it inside by restricting positions to a small overhang.
            let overhangX = t.width / 5, overhangY = t.height / 5
            let xs: ClosedRange<Int>, ys: ClosedRange<Int>
            if let around {
                xs = (around.0 - radius)...(around.0 + radius)
                ys = (around.1 - radius)...(around.1 + radius)
            } else {
                xs = (-overhangX)...(w.width - t.width + overhangX)
                ys = (-overhangY)...(w.height - t.height + overhangY)
            }
            let rowsCount = ys.count
            var best = [(Int, Int, Float)](repeating: (0, 0, -2), count: rowsCount)
            w.data.withUnsafeBufferPointer { wp in
                tpl.withUnsafeBufferPointer { tp in
                    best.withUnsafeMutableBufferPointer { bp in
                        parallelRows(rowsCount) { range in
                            for r in range {
                                let oy = ys.lowerBound + r
                                var rowBest: (Int, Int, Float) = (0, oy, -2)
                                for ox in xs {
                                    var sum: Float = 0, sumSq: Float = 0, dot: Float = 0
                                    for y in 0..<t.height {
                                        let wy = min(w.height - 1, max(0, oy + y))
                                        let wrow = wy * w.width, trow = y * t.width
                                        for x in 0..<t.width {
                                            let v = wp[wrow + min(w.width - 1, max(0, ox + x))]
                                            sum += v; sumSq += v * v; dot += v * tp[trow + x]
                                        }
                                    }
                                    let variance = sumSq - sum * sum / n
                                    let score = variance > 1e-9 ? dot / variance.squareRoot() : -1
                                    if score > rowBest.2 { rowBest = (ox, oy, score) }
                                }
                                bp[r] = rowBest
                            }
                        }
                    }
                }
            }
            return best.max { $0.2 < $1.2 } ?? (0, 0, -2)
        }

        let coarse = search(wideFactor: 16, around: nil, radius: 0)
        let fine = search(wideFactor: 8, around: (coarse.0 * 2, coarse.1 * 2), radius: 3)
        return Location(x: Float(fine.0 * 8), y: Float(fine.1 * 8), score: fine.2)
    }

    /// The telephoto luma shrunk to wide scale and placed in a wide-sized
    /// frame (the wide image itself fills the rest, so the aligner sees no
    /// motion there), plus its footprint on the aligner's 32-pixel tile grid.
    static func paste(tele: Plane, into wide: Plane, at location: Location, magnification: Float) -> (Plane, Plane) {
        let smallW = Int((Float(tele.width) / magnification).rounded())
        let smallH = Int((Float(tele.height) / magnification).rounded())
        // Pre-blur before shrinking to avoid aliasing.
        let small = tele.blurred(sigma: magnification / 2).resized(width: smallW, height: smallH)

        // Match the pasted patch's brightness to the wide image underneath.
        var pasted = wide
        let ox = Int(location.x.rounded()), oy = Int(location.y.rounded())
        var sumS: Float = 0, sumW: Float = 0, count: Float = 0
        for y in stride(from: 0, to: smallH, by: 8) {
            let wy = oy + y
            guard wy >= 0, wy < wide.height else { continue }
            for x in stride(from: 0, to: smallW, by: 8) {
                let wx = ox + x
                guard wx >= 0, wx < wide.width else { continue }
                sumS += small.data[y * smallW + x]; sumW += wide.data[wy * wide.width + wx]; count += 1
            }
        }
        let gain = (count > 0 && sumS > 0) ? sumW / sumS : 1
        for y in 0..<smallH {
            let wy = oy + y
            guard wy >= 0, wy < wide.height else { continue }
            for x in 0..<smallW {
                let wx = ox + x
                guard wx >= 0, wx < wide.width else { continue }
                pasted.data[wy * wide.width + wx] = small.data[y * smallW + x] * gain
            }
        }

        let tile = TileAligner.fullResolutionTile
        let cols = max(1, wide.width / tile), rows = max(1, wide.height / tile)
        var footprint = Plane(width: cols, height: rows)
        for ty in 0..<rows {
            for tx in 0..<cols {
                let cx = (Float(tx) + 0.5) * Float(tile), cy = (Float(ty) + 0.5) * Float(tile)
                // Inside the patch with a one-tile margin.
                let inside = cx > location.x + Float(tile) && cx < location.x + Float(smallW) - Float(tile)
                    && cy > location.y + Float(tile) && cy < location.y + Float(smallH) - Float(tile)
                footprint.data[ty * cols + tx] = inside ? 1 : 0
            }
        }
        return (pasted, footprint)
    }
}

enum Resampler {
    /// Bicubic enlargement of a region of `source`: output pixel (X, Y)
    /// shows source position (originX + (X + 0.5) / scale - 0.5, ...).
    static func enlarge(_ source: RGBPlanes, originX: Float, originY: Float, scale: Float, width: Int, height: Int) -> RGBPlanes {
        func channel(_ p: Plane) -> Plane {
            var out = Plane(width: width, height: height)
            let sw = p.width, sh = p.height
            p.data.withUnsafeBufferPointer { sp in
                out.data.withUnsafeMutableBufferPointer { op in
                    parallelRows(height) { range in
                        var wx = (Float(0), Float(0), Float(0), Float(0)), wy = wx
                        for y in range {
                            let sy = min(Float(sh - 3), max(1, originY + (Float(y) + 0.5) / scale - 0.5))
                            let iy = Int(sy)
                            wy = cubicWeights(sy - Float(iy))
                            for x in 0..<width {
                                let sx = min(Float(sw - 3), max(1, originX + (Float(x) + 0.5) / scale - 0.5))
                                let ix = Int(sx)
                                wx = cubicWeights(sx - Float(ix))
                                var acc: Float = 0
                                let base = (iy - 1) * sw + ix - 1
                                let r0 = sp[base] * wx.0 + sp[base + 1] * wx.1 + sp[base + 2] * wx.2 + sp[base + 3] * wx.3
                                let b1 = base + sw
                                let r1 = sp[b1] * wx.0 + sp[b1 + 1] * wx.1 + sp[b1 + 2] * wx.2 + sp[b1 + 3] * wx.3
                                let b2 = b1 + sw
                                let r2 = sp[b2] * wx.0 + sp[b2 + 1] * wx.1 + sp[b2 + 2] * wx.2 + sp[b2 + 3] * wx.3
                                let b3 = b2 + sw
                                let r3 = sp[b3] * wx.0 + sp[b3 + 1] * wx.1 + sp[b3 + 2] * wx.2 + sp[b3 + 3] * wx.3
                                acc = r0 * wy.0 + r1 * wy.1 + r2 * wy.2 + r3 * wy.3
                                op[y * width + x] = acc
                            }
                        }
                    }
                }
            }
            return out
        }
        return RGBPlanes(r: channel(source.r), g: channel(source.g), b: channel(source.b))
    }

    /// Resamples a telephoto frame onto the output canvas.
    ///
    /// For an output pixel: find its position in the wide frame, add the
    /// aligner's displacement there to get the position in the pasted
    /// (wide-scale) telephoto patch, then scale that up into the telephoto
    /// frame and sample it bicubically. Pixels the telephoto frame doesn't
    /// cover take the canvas's own value and are marked invalid. `valid`
    /// also carries the alignment trust and a feather towards the frame's
    /// edges so tiles blend without seams.
    static func warpTele(
        _ tele: RGBPlanes, onto canvas: RGBPlanes, field: TileField, trust: Plane,
        placement: TelePlacement.Location, magnification: Float,
        cropX: Float, cropY: Float, scale: Float
    ) -> (image: RGBPlanes, valid: Plane) {
        let width = canvas.width, height = canvas.height
        let tw = tele.width, th = tele.height
        var outR = canvas.r, outG = canvas.g, outB = canvas.b
        var valid = Plane(width: width, height: height)
        let tileF = Float(field.tile), cols = field.cols, rows = field.rows
        let feather = Float(min(tw, th)) * 0.06

        tele.r.data.withUnsafeBufferPointer { sr in
        tele.g.data.withUnsafeBufferPointer { sg in
        tele.b.data.withUnsafeBufferPointer { sb in
        outR.data.withUnsafeMutableBufferPointer { dr in
        outG.data.withUnsafeMutableBufferPointer { dg in
        outB.data.withUnsafeMutableBufferPointer { db in
        valid.data.withUnsafeMutableBufferPointer { vp in
        field.dx.withUnsafeBufferPointer { fx in
        field.dy.withUnsafeBufferPointer { fy in
        trust.data.withUnsafeBufferPointer { tp in
            parallelRows(height) { range in
                for y in range {
                    let wy = cropY + (Float(y) + 0.5) / scale - 0.5
                    let gy = min(Float(rows - 1), max(0, (wy + 0.5) / tileF - 0.5))
                    let ty0 = Int(gy), ty1 = min(rows - 1, ty0 + 1)
                    let ay = gy - Float(ty0)
                    for x in 0..<width {
                        let wx = cropX + (Float(x) + 0.5) / scale - 0.5
                        let gx = min(Float(cols - 1), max(0, (wx + 0.5) / tileF - 0.5))
                        let tx0 = Int(gx), tx1 = min(cols - 1, tx0 + 1)
                        let ax = gx - Float(tx0)
                        let i00 = ty0 * cols + tx0, i01 = ty0 * cols + tx1, i10 = ty1 * cols + tx0, i11 = ty1 * cols + tx1
                        let w00 = (1 - ax) * (1 - ay), w01 = ax * (1 - ay), w10 = (1 - ax) * ay, w11 = ax * ay
                        let trustHere = tp[i00] * w00 + tp[i01] * w01 + tp[i10] * w10 + tp[i11] * w11
                        if trustHere <= 0.001 { continue }
                        let ddx = fx[i00] * w00 + fx[i01] * w01 + fx[i10] * w10 + fx[i11] * w11
                        let ddy = fy[i00] * w00 + fy[i01] * w01 + fy[i10] * w10 + fy[i11] * w11

                        // Position in the telephoto frame.
                        let sx = (wx + ddx - placement.x + 0.5) * magnification - 0.5
                        let sy = (wy + ddy - placement.y + 0.5) * magnification - 0.5
                        if sx < 1 || sy < 1 || sx > Float(tw - 3) || sy > Float(th - 3) { continue }

                        let ix = Int(sx), iy = Int(sy)
                        let cx = cubicWeights(sx - Float(ix)), cy = cubicWeights(sy - Float(iy))
                        var r: Float = 0, g: Float = 0, b: Float = 0
                        var row = (iy - 1) * tw + ix - 1
                        for wv in [cy.0, cy.1, cy.2, cy.3] {
                            r += (sr[row] * cx.0 + sr[row + 1] * cx.1 + sr[row + 2] * cx.2 + sr[row + 3] * cx.3) * wv
                            g += (sg[row] * cx.0 + sg[row + 1] * cx.1 + sg[row + 2] * cx.2 + sg[row + 3] * cx.3) * wv
                            b += (sb[row] * cx.0 + sb[row + 1] * cx.1 + sb[row + 2] * cx.2 + sb[row + 3] * cx.3) * wv
                            row += tw
                        }
                        let o = y * width + x
                        dr[o] = r; dg[o] = g; db[o] = b
                        let edge = min(min(sx, Float(tw - 1) - sx), min(sy, Float(th - 1) - sy))
                        vp[o] = trustHere * min(1, edge / feather)
                    }
                }
            }
        }}}}}}}}}}
        return (RGBPlanes(r: outR, g: outG, b: outB), valid)
    }
}

@inline(__always)
func cubicWeights(_ t: Float) -> (Float, Float, Float, Float) {
    let t2 = t * t, t3 = t2 * t
    return (-0.5 * t3 + t2 - 0.5 * t, 1.5 * t3 - 2.5 * t2 + 1, -1.5 * t3 + 2 * t2 + 0.5 * t, 0.5 * t3 - 0.5 * t2)
}

/// Development aid: writes a plane as an 8-bit greyscale PNG.
enum FusionDebug {
    static func write(_ plane: Plane, to path: String, scaleDown: Int) {
        let p = scaleDown > 1 ? plane.downsampled(by: scaleDown) : plane
        let peak = max(1e-6, p.data.max() ?? 1)
        let bytes = p.data.map { UInt8(max(0, min(255, ($0 / peak) * 255))) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: p.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
