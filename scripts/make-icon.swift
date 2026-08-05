// Renders the app icon: an astronaut helmet, white shell and near-black visor, with two stars
// caught in the top right of the glass. Four shapes and no texture, because the same artwork has
// to read at 16 points in the Finder sidebar.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024.0, inset = 100.0, radius = 185.0   // the macOS icon grid: 824 of artwork, corners at 22.4%
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
func disc(_ c: CGPoint, _ r: Double) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

/// Four-pointed glint. The control points sit on the diagonal at `waist` of the radius, which is
/// what pinches the arms in; at 1.0 the same path is a square.
func star(_ c: CGPoint, _ r: Double, waist: Double = 0.30) -> CGPath {
    let p = CGMutablePath(), w = r * waist
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - w, y: c.y + w))
    p.closeSubpath()
    return p
}

ctx.addPath(CGPath(roundedRect: art, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

ctx.drawLinearGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(34, 42, 78), rgb(14, 18, 40), rgb(8, 10, 22)] as CFArray,
                                  locations: [0, 0.55, 1])!,
                       start: px(0.5, 1.02), end: px(0.5, -0.02),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Dome, body and collar as one path: same winding, so the overlaps fill as a single silhouette.
// The body's width equals the dome's diameter, putting the join on the circle's widest point, and
// it takes no corner radius: rounding the top corners nicks the tangent, and the collar covers
// the bottom pair. Every subpath is addRoundedRect so the winding cannot disagree and punch a
// hole through the overlaps.
let shell = CGMutablePath()
shell.addEllipse(in: disc(px(0.5, 0.585), art.width * 0.345))
shell.addRoundedRect(in: box(0.155, 0.285, 0.690, 0.300), cornerWidth: 0, cornerHeight: 0)
shell.addRoundedRect(in: box(0.125, 0.185, 0.750, 0.130), cornerWidth: art.width * 0.050,
                     cornerHeight: art.width * 0.050)

ctx.saveGState()
ctx.addPath(shell)
ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(255, 255, 255), rgb(233, 238, 248), rgb(196, 205, 224)] as CFArray,
                                  locations: [0, 0.5, 1])!,
                       start: px(0.24, 0.96), end: px(0.78, 0.10),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

let visor = CGPath(roundedRect: box(0.265, 0.415, 0.470, 0.380),
                   cornerWidth: art.width * 0.120, cornerHeight: art.width * 0.120, transform: nil)
ctx.saveGState()
ctx.addPath(visor)
ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(28, 34, 56), rgb(12, 15, 28), rgb(6, 7, 14)] as CFArray,
                                  locations: [0, 0.45, 1])!,
                       start: px(0.28, 0.80), end: px(0.72, 0.40),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

ctx.setFillColor(rgb(255, 255, 255))
ctx.addPath(star(px(0.618, 0.690), art.width * 0.056))
ctx.addPath(star(px(0.680, 0.610), art.width * 0.029))
ctx.fillPath()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
guard let image = ctx.makeImage(),
      let sink = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(sink, image, nil)
CGImageDestinationFinalize(sink)
