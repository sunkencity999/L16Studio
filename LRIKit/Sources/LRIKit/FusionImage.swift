import Foundation
import CoreGraphics

/// A single-channel float image, row-major, top row first.
struct Plane {
    let width: Int
    let height: Int
    var data: [Float]

    init(width: Int, height: Int, repeating value: Float = 0) {
        self.width = width
        self.height = height
        data = [Float](repeating: value, count: width * height)
    }

    init(width: Int, height: Int, data: [Float]) {
        precondition(data.count == width * height)
        self.width = width
        self.height = height
        self.data = data
    }
}

/// Linear-light RGB as three planes.
struct RGBPlanes {
    var r: Plane
    var g: Plane
    var b: Plane

    var width: Int { r.width }
    var height: Int { r.height }

    /// Splits interleaved RGBA float pixels (as Core Image renders them).
    init(width: Int, height: Int, rgba: [Float]) {
        var r = Plane(width: width, height: height)
        var g = Plane(width: width, height: height)
        var b = Plane(width: width, height: height)
        rgba.withUnsafeBufferPointer { src in
            r.data.withUnsafeMutableBufferPointer { rp in
                g.data.withUnsafeMutableBufferPointer { gp in
                    b.data.withUnsafeMutableBufferPointer { bp in
                        parallelRows(height) { rows in
                            for y in rows {
                                var i = y * width
                                var s = i * 4
                                for _ in 0..<width {
                                    rp[i] = src[s]; gp[i] = src[s + 1]; bp[i] = src[s + 2]
                                    i += 1; s += 4
                                }
                            }
                        }
                    }
                }
            }
        }
        self.r = r; self.g = g; self.b = b
    }

    init(r: Plane, g: Plane, b: Plane) {
        self.r = r; self.g = g; self.b = b
    }

    /// Perceptually spaced luminance (square root of linear luma), used for
    /// alignment: it evens out noise between shadows and highlights.
    func alignmentLuma() -> Plane {
        var out = luma()
        out.data.withUnsafeMutableBufferPointer { op in
            parallelRows(height) { rows in
                for i in (rows.lowerBound * width)..<(rows.upperBound * width) {
                    op[i] = max(0, op[i]).squareRoot()
                }
            }
        }
        return out
    }

    /// Linear luma.
    func luma() -> Plane {
        var out = Plane(width: width, height: height)
        r.data.withUnsafeBufferPointer { rp in
            g.data.withUnsafeBufferPointer { gp in
                b.data.withUnsafeBufferPointer { bp in
                    out.data.withUnsafeMutableBufferPointer { op in
                        parallelRows(height) { rows in
                            for i in (rows.lowerBound * width)..<(rows.upperBound * width) {
                                op[i] = 0.25 * rp[i] + 0.5 * gp[i] + 0.25 * bp[i]
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// A 32-bit float CGImage in linear Display P3. The pixel buffer is
    /// handed to Core Graphics without copying (at 52 MP it is 830 MB).
    func makeCGImage() -> CGImage? {
        let w = width, h = height
        let count = w * h * 4
        let pixels = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let dst = UnsafeMutableBufferPointer(start: pixels, count: count)
        r.data.withUnsafeBufferPointer { rp in
            g.data.withUnsafeBufferPointer { gp in
                b.data.withUnsafeBufferPointer { bp in
                    parallelRows(h) { rows in
                        for y in rows {
                            var i = y * w
                            var d = i * 4
                            for _ in 0..<w {
                                dst[d] = rp[i]; dst[d + 1] = gp[i]; dst[d + 2] = bp[i]; dst[d + 3] = 1
                                i += 1; d += 4
                            }
                        }
                    }
                }
            }
        }
        let data = Data(bytesNoCopy: pixels, count: count * MemoryLayout<Float>.size, deallocator: .custom { pointer, _ in
            pointer.assumingMemoryBound(to: Float.self).deallocate()
        })
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
            | CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16,
            space: space, bitmapInfo: info, provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Runs `body` over row ranges on all cores.
func parallelRows(_ height: Int, _ body: (Range<Int>) -> Void) {
    let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, height / 16))
    if workers == 1 {
        body(0..<height)
        return
    }
    let chunk = (height + workers - 1) / workers
    withoutActuallyEscaping(body) { body in
        DispatchQueue.concurrentPerform(iterations: workers) { i in
            let start = i * chunk
            let end = min(height, start + chunk)
            if start < end { body(start..<end) }
        }
    }
}

extension Plane {
    /// Halves each dimension by averaging 2x2 blocks.
    func downsampled2() -> Plane {
        let w = width / 2, h = height / 2
        var out = Plane(width: w, height: h)
        let sw = width
        data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                parallelRows(h) { rows in
                    for y in rows {
                        let a = 2 * y * sw, b = a + sw
                        for x in 0..<w {
                            let i = 2 * x
                            dst[y * w + x] = 0.25 * (src[a + i] + src[a + i + 1] + src[b + i] + src[b + i + 1])
                        }
                    }
                }
            }
        }
        return out
    }

    /// Downsamples by an integer factor by averaging blocks.
    func downsampled(by factor: Int) -> Plane {
        let w = width / factor, h = height / factor
        var out = Plane(width: w, height: h)
        let sw = width
        let norm = 1 / Float(factor * factor)
        data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                parallelRows(h) { rows in
                    for y in rows {
                        for x in 0..<w {
                            var sum: Float = 0
                            for yy in 0..<factor {
                                let row = (y * factor + yy) * sw + x * factor
                                for xx in 0..<factor { sum += src[row + xx] }
                            }
                            dst[y * w + x] = sum * norm
                        }
                    }
                }
            }
        }
        return out
    }

    /// Bilinear resize to an arbitrary size.
    func resized(width nw: Int, height nh: Int) -> Plane {
        var out = Plane(width: nw, height: nh)
        let sw = width, sh = height
        let sx = Float(sw) / Float(nw), sy = Float(sh) / Float(nh)
        data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                parallelRows(nh) { rows in
                    for y in rows {
                        let fy = min(Float(sh - 1), max(0, (Float(y) + 0.5) * sy - 0.5))
                        let y0 = Int(fy), y1 = min(sh - 1, y0 + 1)
                        let ty = fy - Float(y0)
                        for x in 0..<nw {
                            let fx = min(Float(sw - 1), max(0, (Float(x) + 0.5) * sx - 0.5))
                            let x0 = Int(fx), x1 = min(sw - 1, x0 + 1)
                            let tx = fx - Float(x0)
                            let top = src[y0 * sw + x0] * (1 - tx) + src[y0 * sw + x1] * tx
                            let bot = src[y1 * sw + x0] * (1 - tx) + src[y1 * sw + x1] * tx
                            dst[y * nw + x] = top * (1 - ty) + bot * ty
                        }
                    }
                }
            }
        }
        return out
    }

    /// Separable Gaussian blur with edge clamping.
    func blurred(sigma: Float) -> Plane {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Float](repeating: 0, count: 2 * radius + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = expf(-Float(i * i) / (2 * sigma * sigma))
            kernel[i + radius] = v
            sum += v
        }
        for i in kernel.indices { kernel[i] /= sum }

        let w = width, h = height
        var tmp = Plane(width: w, height: h)
        var out = Plane(width: w, height: h)
        data.withUnsafeBufferPointer { src in
            tmp.data.withUnsafeMutableBufferPointer { dst in
                kernel.withUnsafeBufferPointer { k in
                    parallelRows(h) { rows in
                        for y in rows {
                            let row = y * w
                            for x in 0..<w {
                                var acc: Float = 0
                                if x >= radius && x < w - radius {
                                    let base = row + x - radius
                                    for i in 0...(2 * radius) { acc += src[base + i] * k[i] }
                                } else {
                                    for i in -radius...radius {
                                        acc += src[row + min(w - 1, max(0, x + i))] * k[i + radius]
                                    }
                                }
                                dst[row + x] = acc
                            }
                        }
                    }
                }
            }
        }
        tmp.data.withUnsafeBufferPointer { src in
            out.data.withUnsafeMutableBufferPointer { dst in
                kernel.withUnsafeBufferPointer { k in
                    parallelRows(h) { rows in
                        for y in rows {
                            let interior = y >= radius && y < h - radius
                            for x in 0..<w {
                                var acc: Float = 0
                                if interior {
                                    var idx = (y - radius) * w + x
                                    for i in 0...(2 * radius) { acc += src[idx] * k[i]; idx += w }
                                } else {
                                    for i in -radius...radius {
                                        acc += src[min(h - 1, max(0, y + i)) * w + x] * k[i + radius]
                                    }
                                }
                                dst[y * w + x] = acc
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}
