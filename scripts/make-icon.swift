// Renders the app icon: an old-school two-reel film projector. Drawn as bold solid shapes with
// no fine detail, because the same artwork has to read at 16 points in the Finder sidebar.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024.0, inset = 100.0, radius = 185.0
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

let art = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
func px(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: art.minX + art.width * x, y: art.minY + art.height * y) }
func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: art.minX + art.width * x, y: art.minY + art.height * y, width: art.width * w, height: art.height * h)
}

ctx.addPath(CGPath(roundedRect: art, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

ctx.drawLinearGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(38, 42, 54), rgb(26, 28, 38), rgb(58, 44, 38)] as CFArray,
                                  locations: [0, 0.55, 1])!,
                       start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

let cream = rgb(240, 233, 219)
ctx.setFillColor(cream)

// The light cone, thrown from the lens and widening to the edge. Drawn before the projector
// so the body sits over its narrow end and the cone reads as leaving the lens.
ctx.saveGState()
let cone = CGMutablePath()
cone.move(to: px(0.655, 0.318))
cone.addLine(to: px(1.04, 0.055))
cone.addLine(to: px(1.04, 0.655))
cone.addLine(to: px(0.655, 0.392))
cone.closeSubpath()
ctx.addPath(cone)
ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(255, 240, 206, 0.80), rgb(255, 228, 168, 0.26),
                                           rgb(255, 222, 155, 0)] as CFArray,
                                  locations: [0, 0.42, 0.94])!,
                       start: px(0.655, 0.355), end: px(1.04, 0.355), options: [])
ctx.restoreGState()

// Feed and take-up reels. Deliberately unequal and set at different heights: two matched
// circles with wide hubs read as a pair of eyes rather than as spools.
for (cx, cy, rf) in [(0.245, 0.670, 0.138), (0.505, 0.588, 0.100)] {
    let c = px(cx, cy), r = art.width * rf
    ctx.setFillColor(cream)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    ctx.setBlendMode(.clear)
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.17, y: c.y - r * 0.17, width: r * 0.34, height: r * 0.34))
    ctx.setBlendMode(.normal)
}

// one rounded slab for the housing and a short barrel, nothing else
ctx.setFillColor(cream)
ctx.addPath(CGPath(roundedRect: box(0.105, 0.262, 0.520, 0.186), cornerWidth: 38, cornerHeight: 38, transform: nil))
ctx.fillPath()
ctx.addPath(CGPath(roundedRect: box(0.600, 0.306, 0.090, 0.098), cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.fillPath()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
guard let image = ctx.makeImage(),
      let sink = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(sink, image, nil)
CGImageDestinationFinalize(sink)
