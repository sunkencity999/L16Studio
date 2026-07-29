import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

let size = 1024
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let rect = CGRect(x: 0, y: 0, width: size, height: size)
let center = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)

// Opaque base layer first -- the bitmap context starts fully transparent,
// and any gradient/path that doesn't cover 100% of its bounds (e.g. a radial
// gradient's un-drawn area inside a non-zero startRadius) would otherwise
// leave a visible transparent hole once flattened to PNG.
ctx.setFillColor(rgb(20, 22, 28))
ctx.fill(rect)

// Background: deep charcoal-to-navy gradient, full bleed (macOS applies its own rounded-square mask).
let bgColors = [rgb(20, 22, 28), rgb(32, 40, 54)] as CFArray
let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Small satellite lenses in a ring, suggesting the L16's multi-lens array --
// abstracted, not a literal 16-dot grid (wouldn't read at small sizes).
let satelliteCount = 8
let satelliteRingRadius: CGFloat = 340
let satelliteRadius: CGFloat = 34
for i in 0..<satelliteCount {
    let angle = (CGFloat(i) / CGFloat(satelliteCount)) * 2 * .pi + (.pi / 2)
    let x = center.x + cos(angle) * satelliteRingRadius
    let y = center.y + sin(angle) * satelliteRingRadius
    ctx.setFillColor(rgb(70, 190, 200, 0.55))
    ctx.fillEllipse(in: CGRect(x: x - satelliteRadius, y: y - satelliteRadius, width: satelliteRadius * 2, height: satelliteRadius * 2))
    ctx.setStrokeColor(rgb(140, 230, 235, 0.8))
    ctx.setLineWidth(4)
    ctx.strokeEllipse(in: CGRect(x: x - satelliteRadius, y: y - satelliteRadius, width: satelliteRadius * 2, height: satelliteRadius * 2))
}

// Main lens: outer ring
let outerRadius: CGFloat = 250
ctx.setStrokeColor(rgb(230, 240, 245))
ctx.setLineWidth(14)
ctx.strokeEllipse(in: CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))

// Main lens: glass gradient fill
let glassRadius: CGFloat = 236
let glassColors = [rgb(60, 140, 200), rgb(20, 60, 100)] as CFArray
let glassGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glassColors, locations: [0, 1])!
ctx.saveGState()
let glassPath = CGPath(ellipseIn: CGRect(x: center.x - glassRadius, y: center.y - glassRadius, width: glassRadius * 2, height: glassRadius * 2), transform: nil)
ctx.addPath(glassPath)
ctx.clip()
ctx.drawRadialGradient(
    glassGradient,
    startCenter: CGPoint(x: center.x - 60, y: center.y + 60), startRadius: 0,
    endCenter: center, endRadius: glassRadius * 1.3,
    options: []
)
ctx.restoreGState()

// Aperture blades (hexagonal iris) in the center
let bladeRadius: CGFloat = 110
let bladeCount = 6
let path = CGMutablePath()
for i in 0..<bladeCount {
    let angle = (CGFloat(i) / CGFloat(bladeCount)) * 2 * .pi - (.pi / 2)
    let x = center.x + cos(angle) * bladeRadius
    let y = center.y + sin(angle) * bladeRadius
    if i == 0 {
        path.move(to: CGPoint(x: x, y: y))
    } else {
        path.addLine(to: CGPoint(x: x, y: y))
    }
}
path.closeSubpath()
ctx.setFillColor(rgb(10, 14, 20, 0.85))
ctx.addPath(path)
ctx.fillPath()

// Lens highlight (small specular dot, upper-left of glass)
ctx.setFillColor(rgb(255, 255, 255, 0.5))
let highlightRect = CGRect(x: center.x - 130, y: center.y + 90, width: 46, height: 46)
ctx.fillEllipse(in: highlightRect)

guard let image = ctx.makeImage() else {
    fatalError("failed to create image")
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("failed to create destination")
}
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(outputURL.path)")
