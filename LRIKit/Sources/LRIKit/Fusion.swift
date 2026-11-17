import Foundation
import CoreGraphics

public enum FusionError: Error, CustomStringConvertible {
    case noReference
    case nothingToMerge

    public var description: String {
        switch self {
        case .noReference: "this shot has no usable colour reference lens"
        case .nothingToMerge: "no other lenses with the reference's focal length could be merged"
        }
    }
}

/// What a fusion run did, for display and for judging the result.
public struct FusionReport: Sendable {
    public struct Frame: Sendable {
        public let camera: CameraID
        /// Median displacement of this lens relative to the reference, in pixels.
        public let medianShift: Float
        /// Largest tile displacement, in pixels (close objects shift most).
        public let maxShift: Float
        /// Share of the picture where this lens agreed with the reference
        /// well enough to contribute (0...1).
        public let coverage: Float
    }
    public let reference: CameraID
    public let frames: [Frame]
    public let seconds: Double
}

/// Stage one of lens fusion: merge every colour lens that shares the
/// reference lens's focal length into one image.
///
/// Each extra lens is aligned to the reference tile by tile (the lenses see
/// the scene from slightly different positions), resampled onto the
/// reference's pixel grid, matched to it in brightness and colour, and then
/// merged. The merge is detail-aware: where a lens is sharper than the
/// others (the camera focuses its modules at different distances) it
/// dominates; where they are equally sharp they are averaged, which lowers
/// noise. A lens is ignored wherever it disagrees with the reference
/// (occlusions near close objects, failed alignment), so problems show up as
/// "no improvement there" instead of ghosting.
public enum WideFusion {
    public typealias Progress = @Sendable (_ message: String, _ fraction: Double) -> Void

    public static func fuse(
        file: LRIFile,
        adjustments: RenderAdjustments = .none,
        sceneLinear: Bool = false,
        progress: Progress? = nil
    ) throws -> (image: CGImage, report: FusionReport) {
        let (planes, report) = try fusePlanes(file: file, adjustments: adjustments, sceneLinear: sceneLinear, progress: progress)
        guard let image = planes.makeCGImage() else { throw ImageRendererError.renderFailed }
        progress?("Done", 1)
        return (image, report)
    }

    static func fusePlanes(
        file: LRIFile,
        adjustments: RenderAdjustments,
        sceneLinear: Bool = false,
        progress: Progress?
    ) throws -> (planes: RGBPlanes, report: FusionReport) {
        let start = Date()
        guard let reference = file.referenceImage ?? file.images.first(where: { $0.cfaPattern != nil }),
              reference.cfaPattern != nil else {
            throw FusionError.noReference
        }
        let sameView = file.images.filter {
            $0.camera != reference.camera
                && $0.camera.focalLength == reference.camera.focalLength
                && $0.width == reference.width && $0.height == reference.height
        }
        // Colour lenses first (they shape tone and colour), then the
        // monochrome lens, which can only contribute luminance detail.
        let includeMono = ProcessInfo.processInfo.environment["L16_FUSION_NO_MONO"] == nil
        let others = sameView.filter { $0.cfaPattern != nil }
            + (includeMono ? sameView.filter { $0.sensor == .ar1335Mono } : [])
        guard !others.isEmpty else { throw FusionError.nothingToMerge }

        let steps = Double(others.count + 2)
        progress?("Developing \(reference.camera.label)", 0)
        let ref = try LensRenderer(image: reference, file: file).renderLinear(adjustments, sceneLinear: sceneLinear)
        let refLuma = ref.alignmentLuma()
        var merger = DetailMerger(reference: ref)

        var frames: [FusionReport.Frame] = []
        for (index, lens) in others.enumerated() {
            progress?("Aligning \(lens.camera.label)", Double(index + 1) / steps)
            let source = try LensRenderer(image: lens, file: file).renderLinear(adjustments, sceneLinear: sceneLinear)
            let field = TileAligner.align(reference: refLuma, target: source.alignmentLuma()).smoothed()
            var (warped, valid) = field.warp(source)
            let trust = field.reliability(width: valid.width, height: valid.height)
            for i in 0..<valid.data.count { valid.data[i] *= trust.data[i] }
            // The monochrome frame is grey in all three channels; tone
            // matching scales each channel to the reference's local colour,
            // and it then adds detail only, so it can't desaturate anything.
            let coverage = merger.add(&warped, valid: valid, detailOnly: lens.cfaPattern == nil)

            let magnitudes = zip(field.dx, field.dy).map { ($0 * $0 + $1 * $1).squareRoot() }.sorted()
            frames.append(.init(
                camera: lens.camera,
                medianShift: magnitudes[magnitudes.count / 2],
                maxShift: magnitudes.last ?? 0,
                coverage: coverage
            ))
        }

        progress?("Merging", (steps - 1) / steps)
        let report = FusionReport(reference: reference.camera, frames: frames, seconds: Date().timeIntervalSince(start))
        return (merger.result(), report)
    }
}

/// Accumulates aligned frames into a two-band (base + detail) weighted merge.
struct DetailMerger {
    /// Split between "base" (tone, colour) and "detail" (texture, edges),
    /// in pixels of the image being merged.
    let bandSigma: Float
    private static let toneFactor = 16
    /// Relative base-band difference at which a frame's weight falls to half.
    let ghostTolerance: Float

    private let width: Int
    private let height: Int
    /// The reference's base band at 1/16 size, for tone matching.
    private let refBaseSmall: RGBPlanes
    private let refBaseLuma: Plane

    private var baseSum: RGBPlanes
    private var detailSum: RGBPlanes
    private var baseWeight: Plane
    private var detailWeight: Plane

    init(reference: RGBPlanes, bandSigma: Float = 2.5, ghostTolerance: Float = 0.10) {
        width = reference.width
        height = reference.height
        self.bandSigma = bandSigma
        self.ghostTolerance = ghostTolerance
        let base = RGBPlanes(
            r: reference.r.blurred(sigma: bandSigma),
            g: reference.g.blurred(sigma: bandSigma),
            b: reference.b.blurred(sigma: bandSigma))
        refBaseSmall = RGBPlanes(
            r: base.r.downsampled(by: Self.toneFactor).blurred(sigma: 2),
            g: base.g.downsampled(by: Self.toneFactor).blurred(sigma: 2),
            b: base.b.downsampled(by: Self.toneFactor).blurred(sigma: 2))
        refBaseLuma = base.luma()

        let sharpness = Self.sharpness(of: reference, base: base, sigma: bandSigma * 1.6)
        // The reference always counts fully in the consistency sense.
        let consistency = Plane(width: width, height: height, repeating: 1)
        baseSum = RGBPlanes(r: Plane(width: width, height: height), g: Plane(width: width, height: height), b: Plane(width: width, height: height))
        detailSum = baseSum
        baseWeight = Plane(width: width, height: height)
        detailWeight = Plane(width: width, height: height)
        accumulate(reference, base: base, sharpness: sharpness, consistency: consistency, includeBase: true)
    }

    /// Local detail energy: blurred magnitude of the luminance detail band.
    private static func sharpness(of image: RGBPlanes, base: RGBPlanes, sigma: Float) -> Plane {
        var detail = image.luma()
        let baseLuma = base.luma()
        let count = detail.data.count
        detail.data.withUnsafeMutableBufferPointer { d in
            baseLuma.data.withUnsafeBufferPointer { b in
                parallelRows(image.height) { rows in
                    for i in (rows.lowerBound * image.width)..<min(count, rows.upperBound * image.width) {
                        d[i] = abs(d[i] - b[i])
                    }
                }
            }
        }
        return detail.blurred(sigma: sigma)
    }

    /// Adds one frame already resampled onto the reference grid. Returns the
    /// share of the picture where it was accepted.
    ///
    /// `detailOnly`: the frame contributes texture but no tone. Used for
    /// telephoto frames, which cover only part of the picture: letting them
    /// shift the base band would leave a visible step at their borders.
    mutating func add(_ frame: inout RGBPlanes, valid: Plane, detailOnly: Bool = false) -> Float {
        // Tone-matched in place: the caller's copy is modified, not duplicated.
        matchTone(&frame, valid: valid)

        let base = RGBPlanes(
            r: frame.r.blurred(sigma: bandSigma),
            g: frame.g.blurred(sigma: bandSigma),
            b: frame.b.blurred(sigma: bandSigma))

        // Consistency: how closely this frame's base band matches the
        // reference's, relative to local brightness.
        var consistency = base.luma()
        let w = width, h = height
        let tol = ghostTolerance
        consistency.data.withUnsafeMutableBufferPointer { c in
            refBaseLuma.data.withUnsafeBufferPointer { r in
                valid.data.withUnsafeBufferPointer { v in
                    parallelRows(h) { rows in
                        for i in (rows.lowerBound * w)..<(rows.upperBound * w) {
                            let d = abs(c[i] - r[i]) / (r[i] + 0.02) / tol
                            let d2 = d * d
                            c[i] = v[i] / (1 + d2 * d2)
                        }
                    }
                }
            }
        }
        // Erode-and-feather: take the minimum of the map and its blur so a
        // rejected area also suppresses its immediate surroundings.
        let soft = consistency.blurred(sigma: bandSigma * 1.2)
        var accepted: Double = 0
        consistency.data.withUnsafeMutableBufferPointer { c in
            soft.data.withUnsafeBufferPointer { s in
                for i in 0..<c.count {
                    c[i] = min(c[i], s[i])
                    accepted += Double(c[i])
                }
            }
        }

        let sharpness = Self.sharpness(of: frame, base: base, sigma: bandSigma * 1.6)
        accumulate(frame, base: base, sharpness: sharpness, consistency: consistency, includeBase: !detailOnly)
        return Float(accepted / Double(w * h))
    }

    /// Matches the frame's low-frequency brightness and colour to the
    /// reference (modules differ slightly in exposure, vignetting and tint).
    private func matchTone(_ frame: inout RGBPlanes, valid: Plane) {
        func gain(_ channel: Plane, _ reference: Plane) -> Plane {
            let b = channel.downsampled(by: Self.toneFactor).blurred(sigma: 2)
            var ratio = Plane(width: reference.width, height: reference.height)
            for i in 0..<ratio.data.count {
                ratio.data[i] = min(2, max(0.5, (reference.data[i] + 0.002) / (b.data[i] + 0.002)))
            }
            return ratio.resized(width: channel.width, height: channel.height)
        }
        func apply(_ channel: inout Plane, _ gain: Plane) {
            let w = channel.width, h = channel.height
            channel.data.withUnsafeMutableBufferPointer { c in
                gain.data.withUnsafeBufferPointer { g in
                    parallelRows(h) { rows in
                        for i in (rows.lowerBound * w)..<(rows.upperBound * w) { c[i] *= g[i] }
                    }
                }
            }
        }
        apply(&frame.r, gain(frame.r, refBaseSmall.r))
        apply(&frame.g, gain(frame.g, refBaseSmall.g))
        apply(&frame.b, gain(frame.b, refBaseSmall.b))
    }

    private mutating func accumulate(_ image: RGBPlanes, base: RGBPlanes, sharpness: Plane, consistency: Plane, includeBase: Bool) {
        Self.accumulate(image.r, base.r, sharpness, consistency, &baseSum.r, &detailSum.r, &baseWeight, &detailWeight, updateWeights: true, includeBase: includeBase)
        Self.accumulate(image.g, base.g, sharpness, consistency, &baseSum.g, &detailSum.g, &baseWeight, &detailWeight, updateWeights: false, includeBase: includeBase)
        Self.accumulate(image.b, base.b, sharpness, consistency, &baseSum.b, &detailSum.b, &baseWeight, &detailWeight, updateWeights: false, includeBase: includeBase)
    }

    private static func accumulate(
        _ img: Plane, _ bse: Plane, _ sharpness: Plane, _ consistency: Plane,
        _ bSum: inout Plane, _ dSum: inout Plane, _ baseWeight: inout Plane, _ detailWeight: inout Plane,
        updateWeights: Bool, includeBase: Bool
    ) {
        let baseScale: Float = includeBase ? 1 : 0
        let w = img.width, h = img.height
        let epsilon: Float = 2e-4
        img.data.withUnsafeBufferPointer { ip in
        bse.data.withUnsafeBufferPointer { bp in
        sharpness.data.withUnsafeBufferPointer { sp in
        consistency.data.withUnsafeBufferPointer { cp in
        bSum.data.withUnsafeMutableBufferPointer { bs in
        dSum.data.withUnsafeMutableBufferPointer { ds in
        baseWeight.data.withUnsafeMutableBufferPointer { bw in
        detailWeight.data.withUnsafeMutableBufferPointer { dw in
            parallelRows(h) { rows in
                for i in (rows.lowerBound * w)..<(rows.upperBound * w) {
                    let s = sp[i] + epsilon
                    // Base band: mild preference for the sharper frame.
                    // Detail band: strong preference (squared), so an
                    // out-of-focus lens can't soften a sharp one.
                    let wb = cp[i] * s * baseScale
                    let wd = cp[i] * s * s
                    bs[i] += wb * bp[i]
                    ds[i] += wd * (ip[i] - bp[i])
                    if updateWeights { bw[i] += wb; dw[i] += wd }
                }
            }
        }}}}}}}}
    }

    /// Finishes the merge. Consumes the accumulators (the result is written
    /// over the base sums), so the merger can't be used afterwards.
    mutating func result() -> RGBPlanes {
        let w = width, h = height
        func finish(_ bSum: inout Plane, _ dSum: Plane) {
            bSum.data.withUnsafeMutableBufferPointer { bs in
            dSum.data.withUnsafeBufferPointer { ds in
            baseWeight.data.withUnsafeBufferPointer { bw in
            detailWeight.data.withUnsafeBufferPointer { dw in
                parallelRows(h) { rows in
                    for i in (rows.lowerBound * w)..<(rows.upperBound * w) {
                        bs[i] = bs[i] / bw[i] + ds[i] / dw[i]
                    }
                }
            }}}}
        }
        finish(&baseSum.r, detailSum.r); detailSum.r = Plane(width: 0, height: 0)
        finish(&baseSum.g, detailSum.g); detailSum.g = Plane(width: 0, height: 0)
        finish(&baseSum.b, detailSum.b); detailSum.b = Plane(width: 0, height: 0)
        let out = baseSum
        baseSum = RGBPlanes(r: Plane(width: 0, height: 0), g: Plane(width: 0, height: 0), b: Plane(width: 0, height: 0))
        baseWeight = Plane(width: 0, height: 0)
        detailWeight = Plane(width: 0, height: 0)
        return out
    }
}
