import Foundation
import CoreGraphics

/// How far away each part of a picture is, measured from the parallax
/// between the camera's wide lenses.
///
/// Values are inverse distance in 1/millimetres on a grid coarser than the
/// picture (`scale` reference pixels per cell): 0 is infinitely far, 0.002
/// is half a metre. Inverse distance is what parallax measures directly,
/// and it is also what blur depends on.
public struct DepthMap: Sendable {
    public let width: Int
    public let height: Int
    /// Reference-image pixels per map cell.
    public let scale: Int
    public let inverseDepth: [Float]
    /// Share of the picture where at least one lens gave a usable measurement
    /// (the rest is filled in from its surroundings).
    public let measured: Float
    /// Focal length of the reference lens in pixels.
    public let focalPixels: Float

    /// Inverse distance at a point given as fractions of the picture's
    /// width and height (0...1 from the top left).
    public func inverseDepth(atX x: Double, y: Double) -> Float {
        let cx = min(width - 1, max(0, Int(x * Double(width))))
        let cy = min(height - 1, max(0, Int(y * Double(height))))
        // A small neighbourhood median, so a click on an edge is stable.
        var values: [Float] = []
        for yy in max(0, cy - 1)...min(height - 1, cy + 1) {
            for xx in max(0, cx - 1)...min(width - 1, cx + 1) {
                values.append(inverseDepth[yy * width + xx])
            }
        }
        values.sort()
        return values[values.count / 2]
    }

    /// Distance in metres at a point, or nil where it is too far to tell.
    public func distance(atX x: Double, y: Double) -> Double? {
        let inverse = inverseDepth(atX: x, y: y)
        return inverse > 1e-6 ? 0.001 / Double(inverse) : nil
    }

    var plane: Plane { Plane(width: width, height: height, data: inverseDepth) }
}

enum DepthEstimator {
    /// One lens's alignment against the reference, with where that lens is.
    struct Observation {
        let geometry: ModuleGeometry
        let field: TileField
        /// The lens's alignment luminance, reduced by `mapScale`.
        let luma: Plane
    }

    /// Map cells are this many reference pixels across.
    static let mapScale = 8

    /// Turns the per-lens alignment fields into a depth map.
    ///
    /// A point at distance Z seen at pixel p in the reference lens appears in
    /// another lens at H(p) + f * t / Z, where H is where it would appear if
    /// it were infinitely far (it depends only on how the two lenses are
    /// turned relative to each other) and t is the other lens's position.
    /// The alignment field gives the actual position, the factory
    /// calibration gives H, f and t, so each lens yields 1/Z, and several
    /// lenses looking along different baselines check each other.
    ///
    /// `guide` is the reference image's luminance at full size; depth edges
    /// are snapped to its edges when the map is refined.
    static func estimate(observations: [Observation], reference: ModuleGeometry, guide: Plane) -> DepthMap? {
        guard let first = observations.first else { return nil }
        let cols = first.field.cols, rows = first.field.rows, tile = first.field.tile
        let count = cols * rows
        guard count > 0, observations.allSatisfy({ $0.field.cols == cols && $0.field.rows == rows }) else { return nil }

        // Residual shift after removing the infinitely-far position, per lens.
        struct Lens {
            var ex: [Double], ey: [Double], trust: [Double]
            var bx: Double, by: Double          // f * t, in pixel-millimetres
            var ox = 0.0, oy = 0.0              // constant correction, pixels
        }
        let kRefInverse = inverse(reference.intrinsics)
        let rRefTransposed = transpose(reference.rotation)
        var lenses: [Lens] = []
        for obs in observations {
            // Relative to the reference lens: how the other lens is turned
            // and where it sits. H = K_other * R_rel * K_ref^-1.
            let rel = multiply(obs.geometry.rotation, rRefTransposed)
            let h = multiply(multiply(obs.geometry.intrinsics, rel), kRefInverse)
            let tr = reference.translation
            let tx = obs.geometry.translation.x - (rel.0 * tr.x + rel.1 * tr.y + rel.2 * tr.z)
            let ty = obs.geometry.translation.y - (rel.3 * tr.x + rel.4 * tr.y + rel.5 * tr.z)
            let grid = obs.field.reliabilityGrid()
            var lens = Lens(
                ex: [Double](repeating: 0, count: count), ey: [Double](repeating: 0, count: count),
                trust: grid.data.map(Double.init),
                bx: Double(obs.geometry.intrinsics.0 * tx),
                by: Double(obs.geometry.intrinsics.4 * ty))
            for ty in 0..<rows {
                for tx in 0..<cols {
                    let i = ty * cols + tx
                    let px = Double(tx * tile) + Double(tile) / 2, py = Double(ty * tile) + Double(tile) / 2
                    let w = Double(h.6) * px + Double(h.7) * py + Double(h.8)
                    let hx = (Double(h.0) * px + Double(h.1) * py + Double(h.2)) / w
                    let hy = (Double(h.3) * px + Double(h.4) * py + Double(h.5)) / w
                    lens.ex[i] = px + Double(obs.field.dx[i]) - hx
                    lens.ey[i] = py + Double(obs.field.dy[i]) - hy
                }
            }
            lenses.append(lens)
        }

        // Solve for inverse depth per tile and a small constant correction
        // per lens, alternately. The correction absorbs calibration drift
        // (a fraction of a degree is several pixels, which matters for far
        // scenes); keeping it small on average pins the overall scale to the
        // factory calibration. A lens is down-weighted on a tile where it
        // disagrees with the consensus, which is how bad alignments drop out.
        var s = [Double](repeating: 0, count: count)
        var weight = [Double](repeating: 0, count: count)
        let tolerance = 4.0   // pixels
        for pass in 0..<5 {
            for i in 0..<count {
                var num = 0.0, den = 0.0
                for lens in lenses {
                    let rx = lens.ex[i] - lens.ox, ry = lens.ey[i] - lens.oy
                    var w = lens.trust[i]
                    if pass > 0 {
                        let dx = rx - s[i] * lens.bx, dy = ry - s[i] * lens.by
                        let miss = (dx * dx + dy * dy) / (tolerance * tolerance)
                        w *= 1 / (1 + miss * miss)
                    }
                    let bb = lens.bx * lens.bx + lens.by * lens.by
                    num += w * (rx * lens.bx + ry * lens.by)
                    den += w * bb
                }
                s[i] = den > 0 ? num / den : 0
                weight[i] = den
            }
            guard pass < 4 else { break }
            for k in lenses.indices {
                var xs: [Double] = [], ys: [Double] = []
                for i in 0..<count where lenses[k].trust[i] > 0.5 && weight[i] > 0 {
                    xs.append(lenses[k].ex[i] - s[i] * lenses[k].bx)
                    ys.append(lenses[k].ey[i] - s[i] * lenses[k].by)
                }
                guard xs.count > 30 else { continue }
                xs.sort(); ys.sort()
                // Half-way to the median each pass, and never more than a
                // degree's worth: enough for drift, not enough to explain
                // away real parallax.
                let limit = 40.0
                lenses[k].ox = max(-limit, min(limit, lenses[k].ox * 0.5 + xs[xs.count / 2] * 0.5))
                lenses[k].oy = max(-limit, min(limit, lenses[k].oy * 0.5 + ys[ys.count / 2] * 0.5))
            }
            // The corrections have one shared freedom (all lenses shifted
            // along their own baselines looks like "everything a bit
            // nearer"). Remove it, so distance stays tied to calibration.
            var num = 0.0, den = 0.0
            for lens in lenses {
                num += lens.ox * lens.bx + lens.oy * lens.by
                den += lens.bx * lens.bx + lens.by * lens.by
            }
            let shared = den > 0 ? num / den : 0
            for k in lenses.indices {
                lenses[k].ox -= shared * lenses[k].bx
                lenses[k].oy -= shared * lenses[k].by
            }
        }

        // What the tiles say about the range of distances in the scene.
        var trusted: [Double] = []
        let full = lenses.reduce(0.0) { $0 + $1.bx * $1.bx + $1.by * $1.by }
        for i in 0..<count where weight[i] > 0.12 * full { trusted.append(max(0, s[i])) }
        guard trusted.count > count / 20 else { return nil }
        trusted.sort()
        let nearest = trusted[min(trusted.count - 1, trusted.count * 99 / 100)]

        // Dense search. For every cell of the map and every candidate
        // distance, look where that point would fall in each other lens and
        // compare. Unlike the tile alignment this only ever searches along
        // the one line geometry allows, so it copes with the very large
        // shifts of close subjects, and all the lenses vote together.
        let scale = mapScale
        let mapW = guide.width / scale, mapH = guide.height / scale
        let cells = mapW * mapH
        let fine = guide.downsampled(by: scale)
        func detail(_ p: Plane) -> Plane {
            // Local contrast only, so exposure differences between lenses
            // and smooth shading don't count as mismatch.
            let soft = p.blurred(sigma: 2.5)
            var out = p
            for i in out.data.indices { out.data[i] -= soft.data[i] }
            return out
        }
        let refDetail = detail(fine)
        let lensDetail = observations.map { detail($0.luma) }

        let longest = lenses.map { ($0.bx * $0.bx + $0.by * $0.by).squareRoot() }.max() ?? 1
        let limit = max(0.0004, nearest * 1.35)                       // 1/mm
        let steps = min(200, max(24, Int((limit * longest / Double(scale)).rounded(.up)) + 1))
        let stepSize = limit / Double(steps - 1)

        // Per lens: where each cell lands when infinitely far (in map
        // cells), and how far it moves per unit of inverse distance.
        struct Sweep { var hx: [Float], hy: [Float], bx: Float, by: Float }
        var sweeps: [Sweep] = []
        for (k, obs) in observations.enumerated() {
            let rel = multiply(obs.geometry.rotation, rRefTransposed)
            let h = multiply(multiply(obs.geometry.intrinsics, rel), kRefInverse)
            var sweep = Sweep(
                hx: [Float](repeating: 0, count: cells), hy: [Float](repeating: 0, count: cells),
                bx: Float(lenses[k].bx / Double(scale)), by: Float(lenses[k].by / Double(scale)))
            for y in 0..<mapH {
                for x in 0..<mapW {
                    let px = (Double(x) + 0.5) * Double(scale) - 0.5, py = (Double(y) + 0.5) * Double(scale) - 0.5
                    let w = Double(h.6) * px + Double(h.7) * py + Double(h.8)
                    let qx = (Double(h.0) * px + Double(h.1) * py + Double(h.2)) / w + lenses[k].ox
                    let qy = (Double(h.3) * px + Double(h.4) * py + Double(h.5)) / w + lenses[k].oy
                    sweep.hx[y * mapW + x] = Float((qx + 0.5) / Double(scale) - 0.5)
                    sweep.hy[y * mapW + x] = Float((qy + 0.5) / Double(scale) - 0.5)
                }
            }
            sweeps.append(sweep)
        }

        var volume = [Float](repeating: 0, count: cells * steps)
        let lensCount = sweeps.count
        volume.withUnsafeMutableBufferPointer { vol in
            DispatchQueue.concurrentPerform(iterations: steps) { level in
                let inverse = Float(Double(level) * stepSize)
                var slice = Plane(width: mapW, height: mapH)
                var costs = [Float](repeating: 0, count: lensCount)
                for y in 0..<mapH {
                    for x in 0..<mapW {
                        let i = y * mapW + x
                        let here = refDetail.data[i]
                        var seen = 0
                        for k in 0..<lensCount {
                            let qx = sweeps[k].hx[i] + inverse * sweeps[k].bx
                            let qy = sweeps[k].hy[i] + inverse * sweeps[k].by
                            guard qx >= 0, qy >= 0, qx < Float(mapW - 1), qy < Float(mapH - 1) else { continue }
                            let x0 = Int(qx), y0 = Int(qy)
                            let tx = qx - Float(x0), ty = qy - Float(y0)
                            let d = lensDetail[k].data
                            let j = y0 * mapW + x0
                            let v = (d[j] * (1 - tx) + d[j + 1] * tx) * (1 - ty) + (d[j + mapW] * (1 - tx) + d[j + mapW + 1] * tx) * ty
                            costs[seen] = abs(v - here)
                            seen += 1
                        }
                        // The better half of the lenses that can see the
                        // point: one blocked or misbehaving lens is ignored.
                        if seen == 0 { slice.data[i] = 0.05; continue }
                        costs[0..<seen].sort()
                        let keep = max(1, (seen + 1) / 2)
                        var sum: Float = 0
                        for n in 0..<keep { sum += costs[n] }
                        slice.data[i] = sum / Float(keep)
                    }
                }
                let smooth = slice.blurred(sigma: 2)
                smooth.data.withUnsafeBufferPointer { sp in
                    for i in 0..<cells { vol[level * cells + i] = sp[i] }
                }
            }
        }

        // How much there is to match on around each cell: none on a plain
        // wall, and none where the picture is blown out (the other lenses
        // clip sooner than the reference, so they can't agree there).
        var texture = refDetail
        for i in 0..<cells { texture.data[i] = abs(texture.data[i]) }
        texture = texture.blurred(sigma: 2)

        // Best distance per cell, refined between levels, and how clearly it
        // beat the alternatives.
        var value = Plane(width: mapW, height: mapH)
        var confidence = Plane(width: mapW, height: mapH)
        volume.withUnsafeBufferPointer { vol in
            for i in 0..<cells {
                var best = 0, bestCost = Float.greatestFiniteMagnitude, total: Float = 0
                for level in 0..<steps {
                    let c = vol[level * cells + i]
                    total += c
                    if c < bestCost { bestCost = c; best = level }
                }
                var rival = Float.greatestFiniteMagnitude
                for level in 0..<steps where abs(level - best) > 2 { rival = min(rival, vol[level * cells + i]) }
                var position = Float(best)
                if best > 0, best < steps - 1 {
                    let a = vol[(best - 1) * cells + i], b = bestCost, c = vol[(best + 1) * cells + i]
                    let curve = a + c - 2 * b
                    if curve > 1e-9 { position += max(-0.5, min(0.5, 0.5 * (a - c) / curve)) }
                }
                value.data[i] = position * Float(stepSize)
                let mean = total / Float(steps)
                let margin = rival < .greatestFiniteMagnitude ? (rival - bestCost) / max(rival, 1e-6) : 0
                // Needs a clear winner, something to match on, and no clipping.
                let textured = min(1, max(0, (texture.data[i] - 0.004) / 0.010))
                let unclipped: Float = fine.data[i] < 0.93 ? 1 : 0
                _ = mean
                confidence.data[i] = max(0, min(1, margin * 3)) * textured * unclipped
            }
        }
        volume = []

        // Spread confident distances into the cells that had nothing to
        // match on (plain walls, blown highlights), following the picture's
        // own edges so a depth step lands on the object's outline.
        var map = value
        var known = confidence
        for (radius, toneWidth) in [(4, Float(0.006)), (9, Float(0.01)), (9, Float(0.02))] {
            var next = map
            var nextKnown = known
            map.data.withUnsafeBufferPointer { mp in
                known.data.withUnsafeBufferPointer { kp in
                    fine.data.withUnsafeBufferPointer { fp in
                        next.data.withUnsafeMutableBufferPointer { np in
                            nextKnown.data.withUnsafeMutableBufferPointer { nk in
                                parallelRows(mapH) { range in
                                    for y in range {
                                        for x in 0..<mapW {
                                            let i = y * mapW + x
                                            let here = fp[i]
                                            var num: Float = 0, den: Float = 0, all: Float = 0
                                            var yy = max(0, y - radius)
                                            while yy <= min(mapH - 1, y + radius) {
                                                var xx = max(0, x - radius)
                                                while xx <= min(mapW - 1, x + radius) {
                                                    let j = yy * mapW + xx
                                                    let dx = Float(xx - x), dy = Float(yy - y)
                                                    let spatial = expf(-(dx * dx + dy * dy) / Float(radius * radius))
                                                    let tone = fp[j] - here
                                                    let w = spatial * expf(-(tone * tone) / toneWidth)
                                                    num += w * kp[j] * mp[j]; den += w * kp[j]; all += w
                                                    xx += 1
                                                }
                                                yy += 1
                                            }
                                            if den > 1e-6 {
                                                np[i] = num / den
                                                nk[i] = max(kp[i], min(1, den / max(all, 1e-6)) * 0.6)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            map = next
            known = nextKnown
        }
        var certain = 0
        for i in 0..<cells where confidence.data[i] > 0.3 { certain += 1 }
        for i in 0..<cells { map.data[i] = max(0, map.data[i]) }

        return DepthMap(
            width: mapW, height: mapH, scale: scale, inverseDepth: map.data,
            measured: Float(certain) / Float(cells), focalPixels: reference.intrinsics.0)
    }

    private static func median3(_ p: Plane) -> Plane {
        var out = p
        var window = [Float](repeating: 0, count: 9)
        for y in 0..<p.height {
            for x in 0..<p.width {
                var n = 0
                for yy in max(0, y - 1)...min(p.height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(p.width - 1, x + 1) {
                        window[n] = p.data[yy * p.width + xx]; n += 1
                    }
                }
                window[0..<n].sort()
                out.data[y * p.width + x] = window[n / 2]
            }
        }
        return out
    }

    private static func multiply(_ a: Matrix3x3, _ b: Matrix3x3) -> Matrix3x3 {
        (a.0 * b.0 + a.1 * b.3 + a.2 * b.6, a.0 * b.1 + a.1 * b.4 + a.2 * b.7, a.0 * b.2 + a.1 * b.5 + a.2 * b.8,
         a.3 * b.0 + a.4 * b.3 + a.5 * b.6, a.3 * b.1 + a.4 * b.4 + a.5 * b.7, a.3 * b.2 + a.4 * b.5 + a.5 * b.8,
         a.6 * b.0 + a.7 * b.3 + a.8 * b.6, a.6 * b.1 + a.7 * b.4 + a.8 * b.7, a.6 * b.2 + a.7 * b.5 + a.8 * b.8)
    }

    private static func transpose(_ m: Matrix3x3) -> Matrix3x3 {
        (m.0, m.3, m.6, m.1, m.4, m.7, m.2, m.5, m.8)
    }

    private static func inverse(_ m: Matrix3x3) -> Matrix3x3 {
        let det = m.0 * (m.4 * m.8 - m.5 * m.7) - m.1 * (m.3 * m.8 - m.5 * m.6) + m.2 * (m.3 * m.7 - m.4 * m.6)
        let d = det == 0 ? 1 : 1 / det
        return ((m.4 * m.8 - m.5 * m.7) * d, (m.2 * m.7 - m.1 * m.8) * d, (m.1 * m.5 - m.2 * m.4) * d,
                (m.5 * m.6 - m.3 * m.8) * d, (m.0 * m.8 - m.2 * m.6) * d, (m.2 * m.3 - m.0 * m.5) * d,
                (m.3 * m.7 - m.4 * m.6) * d, (m.1 * m.6 - m.0 * m.7) * d, (m.0 * m.4 - m.1 * m.3) * d)
    }
}

/// Where to focus and how strongly to blur what is not in focus.
public struct RefocusSettings: Sendable, Hashable, Codable {
    /// The point to keep sharp, as fractions of the picture's width and
    /// height from the top left.
    public var focusX: Double
    public var focusY: Double
    /// Diameter of the imagined lens opening in millimetres. The L16's real
    /// lenses are about 2 mm; 15-30 gives the look of a large-sensor camera.
    public var aperture: Float

    public init(focusX: Double = 0.5, focusY: Double = 0.5, aperture: Float = 18) {
        self.focusX = focusX
        self.focusY = focusY
        self.aperture = aperture
    }
}

/// Blurs a picture by distance from a chosen focus, using a depth map: the
/// shallow depth of field of a large lens, applied afterwards.
public enum Refocus {
    /// Largest blur (Gaussian sigma, in full-size pixels of a 13 MP frame).
    static let maxSigma: Float = 48

    /// `image` must be 32-bit float RGBA as the merge functions return it,
    /// the same size as the reference frame the depth map was made from.
    public static func apply(_ settings: RefocusSettings, to image: CGImage, depth: DepthMap) -> CGImage? {
        let w = image.width, h = image.height
        guard settings.aperture > 0.05, image.bitsPerComponent == 32, image.bitsPerPixel == 128,
              let source = image.dataProvider?.data as Data? else { return image }
        var rgba = [Float](repeating: 0, count: w * h * 4)
        let rowBytes = image.bytesPerRow
        source.withUnsafeBytes { raw in
            rgba.withUnsafeMutableBytes { out in
                for y in 0..<h {
                    out.baseAddress!.advanced(by: y * w * 16)
                        .copyMemory(from: raw.baseAddress!.advanced(by: y * rowBytes), byteCount: w * 16)
                }
            }
        }
        let planes = RGBPlanes(width: w, height: h, rgba: rgba)
        rgba = []
        return apply(settings, to: planes, depth: depth).makeCGImage()
    }

    static func apply(_ settings: RefocusSettings, to image: RGBPlanes, depth: DepthMap) -> RGBPlanes {
        let w = image.width, h = image.height
        let focus = depth.inverseDepth(atX: settings.focusX, y: settings.focusY)
        // Blur circle diameter in pixels = focal length (px) x aperture (mm)
        // x difference in inverse distance (1/mm); a Gaussian of sigma about
        // a quarter of the diameter looks like a disc that size. Scaled so
        // the look is the same whatever size the picture is.
        let gain = depth.focalPixels * settings.aperture / 4 * Float(w) / Float(depth.width * depth.scale)
        var radius = depth.plane
        for i in radius.data.indices {
            radius.data[i] = min(maxSigma, abs(radius.data[i] - focus) * gain)
        }
        // Soften the blur map a little so its cell grid never shows.
        radius = radius.blurred(sigma: 1).resized(width: w, height: h)

        // Blur levels, each made only from pixels that are themselves at
        // least about that blurry, so a sharp subject does not smear into
        // the background behind it.
        let levels: [Float] = [0, 1.5, 3, 6, 12, 24, 48]
        var out = RGBPlanes(r: Plane(width: w, height: h), g: Plane(width: w, height: h), b: Plane(width: w, height: h))
        for (index, sigma) in levels.enumerated() {
            let lower = index > 0 ? levels[index - 1] : 0
            let upper = index + 1 < levels.count ? levels[index + 1] : sigma
            // Tent weight of this level at each pixel.
            func share(_ r: Float) -> Float {
                if index == 0 { return max(0, 1 - r / upper) }
                if r <= sigma { return max(0, (r - lower) / (sigma - lower)) }
                return index + 1 < levels.count ? max(0, 1 - (r - sigma) / (upper - sigma)) : 1
            }
            var level = image
            if index > 0 {
                let factor = sigma >= 48 ? 16 : sigma >= 24 ? 8 : sigma >= 12 ? 4 : sigma >= 6 ? 2 : 1
                let lw = w / factor, lh = h / factor
                let small = factor > 1 ? radius.downsampled(by: factor) : radius
                var mask = Plane(width: lw, height: lh)
                for i in 0..<(lw * lh) {
                    let t = min(1, max(0, (small.data[i] / sigma - 0.3) / 0.4))
                    mask.data[i] = 0.002 + t * t * (3 - 2 * t)
                }
                let s = sigma / Float(factor)
                let weight = mask.blurred(sigma: s)
                func channel(_ p: Plane) -> Plane {
                    var c = factor > 1 ? p.downsampled(by: factor) : p
                    for i in 0..<(lw * lh) { c.data[i] *= mask.data[i] }
                    c = c.blurred(sigma: s)
                    for i in 0..<(lw * lh) { c.data[i] /= weight.data[i] }
                    return factor > 1 ? c.resized(width: w, height: h) : c
                }
                level = RGBPlanes(r: channel(image.r), g: channel(image.g), b: channel(image.b))
            }
            radius.data.withUnsafeBufferPointer { rp in
                func add(_ src: Plane, _ dst: inout Plane) {
                    src.data.withUnsafeBufferPointer { sp in
                        dst.data.withUnsafeMutableBufferPointer { dp in
                            parallelRows(h) { rows in
                                for i in (rows.lowerBound * w)..<(rows.upperBound * w) {
                                    let k = share(rp[i])
                                    if k > 0 { dp[i] += k * sp[i] }
                                }
                            }
                        }
                    }
                }
                add(level.r, &out.r); add(level.g, &out.g); add(level.b, &out.b)
            }
        }
        return out
    }
}

/// Development aid: writes a depth map as a greyscale PNG, near = bright.
public enum DepthDebug {
    public static func write(_ depth: DepthMap, to path: String) {
        // Brightness follows inverse distance up to the 99th percentile.
        let sorted = depth.inverseDepth.sorted()
        let peak = max(1e-9, sorted[min(sorted.count - 1, sorted.count * 99 / 100)])
        var plane = depth.plane
        for i in plane.data.indices { plane.data[i] = min(1, plane.data[i] / peak) }
        plane.data[0] = 1
        FusionDebug.write(plane, to: path, scaleDown: 1)
    }
}
