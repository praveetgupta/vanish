import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Renders the Vanish app icon: a navigation arrow on a blue-to-green gradient
// tile, with a ghost of itself trailing behind — the location left one place
// and reappeared somewhere else, which is the whole app in one mark.
//
// Usage: swift make_icon.swift <app-icon-1024.png>

func writePNG(_ image: CGImage, to path: String) {
    #if canImport(UniformTypeIdentifiers)
    let utType = UTType.png.identifier
    #else
    let utType = "public.png"
    #endif
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, utType as CFString, 1, nil) else {
        fatalError("could not create image destination at \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write png to \(path)") }
    print("wrote \(path)")
}

func makeContext(size: Int) -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create CGContext")
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

/// The navigation arrow, as a closed path centred on `center`.
///
/// Points up-right at 45°, the orientation Apple uses for `location.fill`, with
/// a notch cut into the tail so it reads as an arrow rather than a triangle.
func arrowPath(center: CGPoint, radius r: CGFloat, rotation: CGFloat) -> CGPath {
    // Normalised outline, tip at (0, 1), notch cut up into the tail.
    let points: [CGPoint] = [
        CGPoint(x: 0.00, y: 1.00),     // tip
        CGPoint(x: -0.62, y: -0.78),   // left tail
        CGPoint(x: 0.00, y: -0.30),    // notch
        CGPoint(x: 0.62, y: -0.78),    // right tail
    ]
    // Scale, then rotate, then translate — CGAffineTransform composes so that
    // the last modifier applied is the first one the points see.
    let transform = CGAffineTransform(translationX: center.x, y: center.y)
        .rotated(by: rotation)
        .scaledBy(x: r, y: r)

    let path = CGMutablePath()
    path.addLines(between: points, transform: transform)
    path.closeSubpath()
    return path
}

let args = CommandLine.arguments
let appIconPath = args.count > 1 ? args[1] : "AppIcon.png"

#if canImport(CoreGraphics) && canImport(ImageIO)

let size = 1024
let ctx = makeContext(size: size)
let w = CGFloat(size)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// macOS icon grid: an 824×824 tile centred in a 1024 canvas, corner radius ≈ 22.37 %.
let tileSide = w * 0.824
let tileOrigin = (w - tileSide) / 2
let tileRect = CGRect(x: tileOrigin, y: tileOrigin, width: tileSide, height: tileSide)
let cornerRadius = tileSide * 0.2237

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tileRect, cornerWidth: cornerRadius,
                   cornerHeight: cornerRadius, transform: nil))
ctx.clip()

// Deep navy at the top falling to the same green the map puck uses, so the icon
// and the running app share a colour.
let topColor    = CGColor(red: 0.07, green: 0.16, blue: 0.38, alpha: 1.0)
let midColor    = CGColor(red: 0.05, green: 0.42, blue: 0.55, alpha: 1.0)
let bottomColor = CGColor(red: 0.14, green: 0.76, blue: 0.42, alpha: 1.0)
if let grad = CGGradient(colorsSpace: space,
                         colors: [topColor, midColor, bottomColor] as CFArray,
                         locations: [0.0, 0.55, 1.0]) {
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
                           end: CGPoint(x: tileRect.maxX, y: tileRect.minY),
                           options: [])
}

// Soft highlight across the top for a little depth.
if let gloss = CGGradient(colorsSpace: space,
                          colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
                                   CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                          locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: w / 2, y: tileRect.maxY),
                           end: CGPoint(x: w / 2, y: tileRect.midY),
                           options: [])
}

// Compose around a focal point nudged up-right, leaving the lower-left quadrant
// for the trail the arrow came from.
let focus = CGPoint(x: w / 2 + tileSide * 0.055, y: w / 2 + tileSide * 0.045)
let arrowRadius = tileSide * 0.260
let rotation: CGFloat = -.pi / 4        // point up-right

// One accuracy ring, the GPS idiom. A second ring crowded the glyph and turned
// to mush below 32 pt, so the mark carries a single circle that simply fades
// out at small sizes.
let ringRadius = tileSide * 0.360
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.20))
ctx.setLineWidth(tileSide * 0.015)
ctx.addEllipse(in: CGRect(x: focus.x - ringRadius, y: focus.y - ringRadius,
                          width: ringRadius * 2, height: ringRadius * 2))
ctx.strokePath()

// The ghost: where the phone used to think it was. Offset far enough down the
// arrow's own axis that the two never touch — one clean jump reads better at
// 16 pt than a crowd of fading copies.
// The offset is applied on both axes, so the separation along the arrow's own
// 45-degree axis is this times sqrt(2) — enough to clear the arrow's tail.
let ghostScale: CGFloat = 0.72
let ghostDistance = arrowRadius * 1.238
let ghostCenter = CGPoint(x: focus.x - ghostDistance, y: focus.y - ghostDistance)

ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
ctx.addPath(arrowPath(center: ghostCenter, radius: arrowRadius * ghostScale, rotation: rotation))
ctx.fillPath()

// The arrow itself, with a drop shadow so it lifts off the gradient.
ctx.setShadow(offset: CGSize(width: 0, height: -tileSide * 0.016),
              blur: tileSide * 0.045,
              color: CGColor(red: 0, green: 0.05, blue: 0.1, alpha: 0.42))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(arrowPath(center: focus, radius: arrowRadius, rotation: rotation))
ctx.fillPath()

ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("could not make icon CGImage") }
writePNG(image, to: appIconPath)

#else
fatalError("CoreGraphics/ImageIO unavailable")
#endif
