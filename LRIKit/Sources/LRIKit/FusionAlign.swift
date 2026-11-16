import Foundation

/// A grid of per-tile displacements: for a reference pixel inside a tile,
/// the matching target pixel is at `(x + dx, y + dy)`.
struct TileField {
    let tile: Int
    let cols: Int
    let rows: Int
    var dx: [Float]
    var dy: [Float]

    init(tile: Int, cols: Int, rows: Int) {
        self.tile = tile
        self.cols = cols
        self.rows = rows
        dx = [Float](repeating: 0, count: cols * rows)
        dy = [Float](repeating: 0, count: cols * rows)
    }
}

/// Coarse-to-fine block matching between two views of the same scene.
///
/// The L16's modules sit a few centimetres apart, so the shift between two
/// lenses depends on distance: nearly zero for far objects, hundreds of
/// pixels for close ones. A single global transform can't describe that, so
/// each tile gets its own displacement, found on an image pyramid: an
/// exhaustive search at the coarsest level, then a small refinement around
/// the inherited displacement at each finer level, and a sub-pixel fit at
/// full resolution. (The same scheme burst-photography pipelines use.)
enum TileAligner {
    static let coarseSearch = 16
    static let fineSearch = 2

    static func align(reference: Plane, target: Plane) -> TileField {
        // Pyramid: level 0 is full resolution.
        var refLevels = [reference], tgtLevels = [target]
        while min(refLevels.last!.width, refLevels.last!.height) >= 160 {
            refLevels.append(refLevels.last!.downsampled2())
            tgtLevels.append(tgtLevels.last!.downsampled2())
        }

        var field: TileField?
        for level in stride(from: refLevels.count - 1, through: 0, by: -1) {
            let ref = refLevels[level], tgt = tgtLevels[level]
            let tile = level == 0 ? 32 : 16
            let cols = max(1, ref.width / tile), rows = max(1, ref.height / tile)
            var next = TileField(tile: tile, cols: cols, rows: rows)

            if let parent = field {
                // Inherit from the parent tile under this tile's centre.
                for ty in 0..<rows {
                    for tx in 0..<cols {
                        let cx = (Float(tx) + 0.5) * Float(tile) / 2
                        let cy = (Float(ty) + 0.5) * Float(tile) / 2
                        let px = min(parent.cols - 1, Int(cx) / parent.tile)
                        let py = min(parent.rows - 1, Int(cy) / parent.tile)
                        next.dx[ty * cols + tx] = 2 * parent.dx[py * parent.cols + px]
                        next.dy[ty * cols + tx] = 2 * parent.dy[py * parent.cols + px]
                    }
                }
            }
            search(ref: ref, tgt: tgt, field: &next, radius: field == nil ? coarseSearch : fineSearch)
            regularise(ref: ref, tgt: tgt, field: &next)
            field = next
        }

        var result = field!
        refineSubpixel(ref: refLevels[0], tgt: tgtLevels[0], field: &result)
        diffuse(ref: refLevels[0], field: &result)
        return result
    }

    /// Confidence-weighted smoothing. A tile with real texture keeps its own
    /// measurement; a featureless tile (plain wall, blurred background) has
    /// nothing to match on and only found noise, so it takes its displacement
    /// from its neighbours instead. Texture is judged against the image's
    /// own noise floor (the 20th-percentile tile contrast).
    private static func diffuse(ref: Plane, field: inout TileField, iterations: Int = 16) {
        let tile = field.tile, cols = field.cols, rows = field.rows, w = ref.width
        var contrast = [Float](repeating: 0, count: cols * rows)
        ref.data.withUnsafeBufferPointer { rp in
            for ty in 0..<rows {
                for tx in 0..<cols {
                    var sum: Float = 0, sumSq: Float = 0
                    for y in 0..<tile {
                        let row = (ty * tile + y) * w + tx * tile
                        for x in 0..<tile { let v = rp[row + x]; sum += v; sumSq += v * v }
                    }
                    let n = Float(tile * tile)
                    contrast[ty * cols + tx] = max(0, sumSq / n - (sum / n) * (sum / n)).squareRoot()
                }
            }
        }
        let floor = contrast.sorted()[contrast.count / 5]
        let threshold = max(1e-4, 3 * floor)
        let confidence = contrast.map { c -> Float in
            let r = c / threshold
            return r * r / (1 + r * r)
        }

        let measuredX = field.dx, measuredY = field.dy
        for _ in 0..<iterations {
            let curX = field.dx, curY = field.dy
            for ty in 0..<rows {
                for tx in 0..<cols {
                    var ax: Float = 0, ay: Float = 0, n: Float = 0
                    for ny in max(0, ty - 1)...min(rows - 1, ty + 1) {
                        for nx in max(0, tx - 1)...min(cols - 1, tx + 1) where nx != tx || ny != ty {
                            ax += curX[ny * cols + nx]; ay += curY[ny * cols + nx]; n += 1
                        }
                    }
                    let i = ty * cols + tx
                    let c = confidence[i]
                    field.dx[i] = c * measuredX[i] + (1 - c) * ax / n
                    field.dy[i] = c * measuredY[i] + (1 - c) * ay / n
                }
            }
        }
    }

    /// Mean-removed sum of absolute differences between a reference tile and
    /// the target tile displaced by (ox, oy). Mean removal makes the match
    /// insensitive to brightness differences between modules.
    @inline(__always)
    private static func cost(
        _ ref: UnsafeBufferPointer<Float>, _ tgt: UnsafeBufferPointer<Float>,
        width: Int, height: Int, x0: Int, y0: Int, tile: Int, ox: Int, oy: Int
    ) -> Float {
        var sumR: Float = 0, sumT: Float = 0
        let count = Float(tile * tile)
        for y in 0..<tile {
            let ry = y0 + y
            let ty = min(height - 1, max(0, ry + oy))
            let rrow = ry * width + x0
            let trow = ty * width
            for x in 0..<tile {
                sumR += ref[rrow + x]
                sumT += tgt[trow + min(width - 1, max(0, x0 + x + ox))]
            }
        }
        let bias = (sumT - sumR) / count
        var sad: Float = 0
        for y in 0..<tile {
            let ry = y0 + y
            let ty = min(height - 1, max(0, ry + oy))
            let rrow = ry * width + x0
            let trow = ty * width
            for x in 0..<tile {
                sad += abs(tgt[trow + min(width - 1, max(0, x0 + x + ox))] - ref[rrow + x] - bias)
            }
        }
        return sad
    }

    private static func search(ref: Plane, tgt: Plane, field: inout TileField, radius: Int) {
        let w = ref.width, h = ref.height, tile = field.tile, cols = field.cols, rows = field.rows
        ref.data.withUnsafeBufferPointer { rp in
            tgt.data.withUnsafeBufferPointer { tp in
                field.dx.withUnsafeMutableBufferPointer { dxp in
                    field.dy.withUnsafeMutableBufferPointer { dyp in
                        parallelRows(rows) { range in
                            for ty in range {
                                for tx in 0..<cols {
                                    let i = ty * cols + tx
                                    let bx = Int(dxp[i].rounded()), by = Int(dyp[i].rounded())
                                    var best = Float.greatestFiniteMagnitude
                                    var bestX = bx, bestY = by
                                    for oy in (by - radius)...(by + radius) {
                                        for ox in (bx - radius)...(bx + radius) {
                                            // A tiny penalty on distance from the inherited
                                            // offset breaks ties in featureless tiles.
                                            let c = cost(rp, tp, width: w, height: h, x0: tx * tile, y0: ty * tile, tile: tile, ox: ox, oy: oy)
                                                + 0.0005 * Float(tile * tile) * Float(abs(ox - bx) + abs(oy - by)) / Float(radius)
                                            if c < best { best = c; bestX = ox; bestY = oy }
                                        }
                                    }
                                    dxp[i] = Float(bestX); dyp[i] = Float(bestY)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Where a tile's own best match is barely better than the median of its
    /// neighbours' displacements, adopt the median. Featureless tiles (walls,
    /// sky) otherwise lock onto noise and tear the image when warped.
    private static func regularise(ref: Plane, tgt: Plane, field: inout TileField) {
        let w = ref.width, h = ref.height, tile = field.tile, cols = field.cols, rows = field.rows
        let oldX = field.dx, oldY = field.dy
        ref.data.withUnsafeBufferPointer { rp in
            tgt.data.withUnsafeBufferPointer { tp in
                field.dx.withUnsafeMutableBufferPointer { dxp in
                    field.dy.withUnsafeMutableBufferPointer { dyp in
                        parallelRows(rows) { range in
                            var xs = [Float](), ys = [Float]()
                            for ty in range {
                                for tx in 0..<cols {
                                    xs.removeAll(keepingCapacity: true); ys.removeAll(keepingCapacity: true)
                                    for ny in max(0, ty - 1)...min(rows - 1, ty + 1) {
                                        for nx in max(0, tx - 1)...min(cols - 1, tx + 1) {
                                            xs.append(oldX[ny * cols + nx]); ys.append(oldY[ny * cols + nx])
                                        }
                                    }
                                    xs.sort(); ys.sort()
                                    let mx = Int(xs[xs.count / 2].rounded()), my = Int(ys[ys.count / 2].rounded())
                                    let i = ty * cols + tx
                                    let ox = Int(oldX[i]), oy = Int(oldY[i])
                                    if mx == ox && my == oy { continue }
                                    let own = cost(rp, tp, width: w, height: h, x0: tx * tile, y0: ty * tile, tile: tile, ox: ox, oy: oy)
                                    let med = cost(rp, tp, width: w, height: h, x0: tx * tile, y0: ty * tile, tile: tile, ox: mx, oy: my)
                                    if med <= own * 1.08 + 0.002 * Float(tile * tile) {
                                        dxp[i] = Float(mx); dyp[i] = Float(my)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Fits a parabola through the match cost at -1, 0, +1 in each axis.
    private static func refineSubpixel(ref: Plane, tgt: Plane, field: inout TileField) {
        let w = ref.width, h = ref.height, tile = field.tile, cols = field.cols, rows = field.rows
        ref.data.withUnsafeBufferPointer { rp in
            tgt.data.withUnsafeBufferPointer { tp in
                field.dx.withUnsafeMutableBufferPointer { dxp in
                    field.dy.withUnsafeMutableBufferPointer { dyp in
                        parallelRows(rows) { range in
                            for ty in range {
                                for tx in 0..<cols {
                                    let i = ty * cols + tx
                                    let ox = Int(dxp[i]), oy = Int(dyp[i])
                                    func c(_ ax: Int, _ ay: Int) -> Float {
                                        cost(rp, tp, width: w, height: h, x0: tx * tile, y0: ty * tile, tile: tile, ox: ox + ax, oy: oy + ay)
                                    }
                                    let c0 = c(0, 0)
                                    let l = c(-1, 0), r = c(1, 0), u = c(0, -1), d = c(0, 1)
                                    let denomX = l - 2 * c0 + r, denomY = u - 2 * c0 + d
                                    if denomX > 1e-6 { dxp[i] += max(-0.5, min(0.5, 0.5 * (l - r) / denomX)) }
                                    if denomY > 1e-6 { dyp[i] += max(-0.5, min(0.5, 0.5 * (u - d) / denomY)) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension TileField {
    /// Smooths the displacement grid (3x3 binomial) so neighbouring tiles
    /// blend instead of stepping.
    func smoothed() -> TileField {
        var out = self
        for (src, keyPath) in [(dx, \TileField.dx), (dy, \TileField.dy)] {
            var result = src
            for ty in 0..<rows {
                for tx in 0..<cols {
                    var acc: Float = 0, weight: Float = 0
                    for (oy, wy) in [(-1, Float(1)), (0, 2), (1, 1)] {
                        for (ox, wx) in [(-1, Float(1)), (0, 2), (1, 1)] {
                            let ny = ty + oy, nx = tx + ox
                            guard ny >= 0, ny < rows, nx >= 0, nx < cols else { continue }
                            acc += src[ny * cols + nx] * wx * wy
                            weight += wx * wy
                        }
                    }
                    result[ty * cols + tx] = acc / weight
                }
            }
            out[keyPath: keyPath] = result
        }
        return out
    }

    /// Per-pixel trust in the warp, 0...1. Where the displacement field
    /// *bends* sharply (depth edges, occlusions, tiles that matched the wrong
    /// thing) the warped image is torn, so that area must not contribute to a
    /// merge. Bending is measured as the second difference, so a steady
    /// gradient -- a receding surface such as a desk or floor, where the
    /// shift changes smoothly with distance -- is still trusted.
    func reliability(width: Int, height: Int, tolerance: Float = 2.5) -> Plane {
        reliabilityGrid(tolerance: tolerance).resized(width: width, height: height)
    }

    /// The same trust measure on the tile grid itself (one value per tile).
    func reliabilityGrid(tolerance: Float = 2.5) -> Plane {
        var grid = Plane(width: cols, height: rows)
        func bend(_ d: [Float], _ tx: Int, _ ty: Int) -> Float {
            let i = ty * cols + tx
            var b: Float = 0
            if tx > 0, tx < cols - 1 { b = max(b, abs(d[i - 1] + d[i + 1] - 2 * d[i])) }
            if ty > 0, ty < rows - 1 { b = max(b, abs(d[i - cols] + d[i + cols] - 2 * d[i])) }
            return b
        }
        for ty in 0..<rows {
            for tx in 0..<cols {
                let r = max(bend(dx, tx, ty), bend(dy, tx, ty)) / tolerance
                grid.data[ty * cols + tx] = 1 / (1 + r * r * r * r)
            }
        }
        // Erode by one tile so the tiles next to a break are distrusted too.
        var eroded = grid
        for ty in 0..<rows {
            for tx in 0..<cols {
                var m: Float = 1
                for ny in max(0, ty - 1)...min(rows - 1, ty + 1) {
                    for nx in max(0, tx - 1)...min(cols - 1, tx + 1) {
                        m = min(m, grid.data[ny * cols + nx])
                    }
                }
                eroded.data[ty * cols + tx] = m
            }
        }
        return eroded
    }

    /// Resamples `source` onto the reference grid: output(x, y) =
    /// source(x + dx, y + dy), with displacements interpolated bilinearly
    /// between tile centres and the image sampled with a Catmull-Rom bicubic
    /// (bilinear sampling would soften the detail we are trying to gain).
    /// `valid` is 1 where the sample came from inside the source.
    func warp(_ source: RGBPlanes) -> (image: RGBPlanes, valid: Plane) {
        let w = source.width, h = source.height
        var outR = Plane(width: w, height: h), outG = Plane(width: w, height: h), outB = Plane(width: w, height: h)
        var valid = Plane(width: w, height: h)
        let tileF = Float(tile)
        let cols = cols, rows = rows

        source.r.data.withUnsafeBufferPointer { sr in
        source.g.data.withUnsafeBufferPointer { sg in
        source.b.data.withUnsafeBufferPointer { sb in
        outR.data.withUnsafeMutableBufferPointer { dr in
        outG.data.withUnsafeMutableBufferPointer { dg in
        outB.data.withUnsafeMutableBufferPointer { db in
        valid.data.withUnsafeMutableBufferPointer { vp in
        dx.withUnsafeBufferPointer { fx in
        dy.withUnsafeBufferPointer { fy in
            parallelRows(h) { range in
                var wx = [Float](repeating: 0, count: 4), wy = [Float](repeating: 0, count: 4)
                for y in range {
                    let gy = min(Float(rows - 1), max(0, (Float(y) + 0.5) / tileF - 0.5))
                    let ty0 = Int(gy), ty1 = min(rows - 1, ty0 + 1)
                    let ay = gy - Float(ty0)
                    for x in 0..<w {
                        let gx = min(Float(cols - 1), max(0, (Float(x) + 0.5) / tileF - 0.5))
                        let tx0 = Int(gx), tx1 = min(cols - 1, tx0 + 1)
                        let ax = gx - Float(tx0)
                        let i00 = ty0 * cols + tx0, i01 = ty0 * cols + tx1, i10 = ty1 * cols + tx0, i11 = ty1 * cols + tx1
                        let ddx = (fx[i00] * (1 - ax) + fx[i01] * ax) * (1 - ay) + (fx[i10] * (1 - ax) + fx[i11] * ax) * ay
                        let ddy = (fy[i00] * (1 - ax) + fy[i01] * ax) * (1 - ay) + (fy[i10] * (1 - ax) + fy[i11] * ax) * ay

                        let sx = Float(x) + ddx, sy = Float(y) + ddy
                        let o = y * w + x
                        if sx < 1 || sy < 1 || sx > Float(w - 3) || sy > Float(h - 3) {
                            // Outside the source: fall back to the nearest edge pixel and mark invalid.
                            let cx = min(w - 1, max(0, Int(sx.rounded()))), cy = min(h - 1, max(0, Int(sy.rounded())))
                            let si = cy * w + cx
                            dr[o] = sr[si]; dg[o] = sg[si]; db[o] = sb[si]
                            vp[o] = 0
                            continue
                        }
                        let ix = Int(sx), iy = Int(sy)
                        let tx = sx - Float(ix), ty = sy - Float(iy)
                        catmullRom(tx, &wx); catmullRom(ty, &wy)
                        var r: Float = 0, g: Float = 0, b: Float = 0
                        for j in 0..<4 {
                            let row = (iy - 1 + j) * w + ix - 1
                            let rr = sr[row] * wx[0] + sr[row + 1] * wx[1] + sr[row + 2] * wx[2] + sr[row + 3] * wx[3]
                            let gg = sg[row] * wx[0] + sg[row + 1] * wx[1] + sg[row + 2] * wx[2] + sg[row + 3] * wx[3]
                            let bb = sb[row] * wx[0] + sb[row + 1] * wx[1] + sb[row + 2] * wx[2] + sb[row + 3] * wx[3]
                            r += rr * wy[j]; g += gg * wy[j]; b += bb * wy[j]
                        }
                        dr[o] = r; dg[o] = g; db[o] = b
                        vp[o] = 1
                    }
                }
            }
        }}}}}}}}}
        return (RGBPlanes(r: outR, g: outG, b: outB), valid)
    }
}

@inline(__always)
private func catmullRom(_ t: Float, _ w: inout [Float]) {
    let t2 = t * t, t3 = t2 * t
    w[0] = -0.5 * t3 + t2 - 0.5 * t
    w[1] = 1.5 * t3 - 2.5 * t2 + 1
    w[2] = -1.5 * t3 + 2 * t2 + 0.5 * t
    w[3] = 0.5 * t3 - 0.5 * t2
}
