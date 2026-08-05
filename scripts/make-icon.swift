// Renders the app icon: an astronaut helmet. Two flat colours and no gradient anywhere, so the
// silhouette and the round visor carry it alone. Built as a ring with an ear pod each side and
// the collar sitting clear below it: fusing the collar into the circle puts a concave nick
// wherever a rounded rect's corner meets a narrowing arc, and no radius avoids it.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024.0, inset = 100.0, radius = 185.0   // the macOS icon grid: 824 of artwork, corners at 22.4%
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func rgb(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, 1])!
}
let field = rgb(24, 27, 42), shellInk = rgb(255, 255, 255)

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
ctx.setFillColor(field)
ctx.fill(art.insetBy(dx: -inset, dy: -inset))

let helmet = px(0.5, 0.580)

let shell = CGMutablePath()
shell.addEllipse(in: disc(helmet, art.width * 0.305))
for x in [0.143, 0.764] {
    shell.addRoundedRect(in: box(x, 0.465, 0.093, 0.160), cornerWidth: art.width * 0.040,
                         cornerHeight: art.width * 0.040)
}
shell.addRoundedRect(in: box(0.325, 0.130, 0.350, 0.108), cornerWidth: art.width * 0.052,
                     cornerHeight: art.width * 0.052)

ctx.setFillColor(shellInk)
ctx.addPath(shell)
ctx.fillPath()

ctx.setFillColor(field)
ctx.fillEllipse(in: disc(helmet, art.width * 0.228))

ctx.setFillColor(shellInk)
ctx.addPath(star(px(0.610, 0.672), art.width * 0.047))
ctx.addPath(star(px(0.672, 0.618), art.width * 0.025))
ctx.fillPath()

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
guard let image = ctx.makeImage(),
      let sink = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(sink, image, nil)
CGImageDestinationFinalize(sink)
