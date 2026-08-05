// Renders the app icon: an orbital sunrise, the shot most of Apple's aerials open on. What
// identifies it is the atmosphere seen edge-on, white at the limb through orange and green into
// blue against black space, so that band carries a fifth of the artwork and everything else is
// flat. No fine detail: the same image has to read at 16 points in the Finder sidebar.
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
func disc(_ c: CGPoint, _ r: Double) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }

// The planet sits mostly below the frame, so only a shallow arc crosses the icon. Centre and
// radius set the curvature: shrinking the radius bows the horizon harder.
let planet = px(0.5, -0.85), planetR = art.width * 1.15
let sun = px(0.5, 0.625), sunR = art.width * 0.088
let sky = art.width * 0.20                  // atmosphere thickness, measured out from the limb

// Colour against fraction of the way in to the limb, so 1.0 is the horizon itself. Warm stops
// take the inner third because warm-over-dark is what survives the downscale to 16 points.
let stops: [(u: Double, r: Double, g: Double, b: Double, a: Double)] = [
    (0.00,  10,  16,  38, 0.00),
    (0.30,  16,  32,  78, 0.85),
    (0.50,  26,  92, 140, 1.00),
    (0.68,  74, 168, 152, 1.00),
    (0.82, 214, 186, 104, 1.00),
    (0.92, 240, 142,  62, 1.00),
    (1.00, 255, 240, 214, 1.00),
]

func atmosphere(_ u: Double) -> CGColor {
    guard let i = stops.firstIndex(where: { u <= $0.u }), i > 0 else { return rgb(10, 16, 38, 0) }
    let lo = stops[i - 1], hi = stops[i], f = (u - lo.u) / (hi.u - lo.u)
    return rgb(lo.r + (hi.r - lo.r) * f, lo.g + (hi.g - lo.g) * f,
               lo.b + (hi.b - lo.b) * f, lo.a + (hi.a - lo.a) * f)
}

ctx.addPath(CGPath(roundedRect: art, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

ctx.drawLinearGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(3, 4, 11), rgb(7, 9, 20)] as CFArray, locations: [0, 1])!,
                       start: px(0.5, 1.02), end: px(0.5, 0.30),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Under the bands, which are opaque and cut it off at the top of the atmosphere. Saturated
// orange rather than cream: a pale colour at this alpha over black composites to warm grey.
ctx.drawRadialGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(255, 168, 58, 0.40), rgb(255, 138, 40, 0.11),
                                           rgb(255, 128, 40, 0)] as CFArray,
                                  locations: [0, 0.4, 1])!,
                       startCenter: sun, startRadius: 0, endCenter: sun, endRadius: art.width * 0.34,
                       options: [])

// Concentric discs outward-in. Every band picks up the limb's curvature for free, and the alpha
// ramp on the outermost stops blends the top of the atmosphere into space.
let steps = 140
for i in 0...steps {
    let u = Double(i) / Double(steps)
    ctx.setFillColor(atmosphere(u))
    ctx.fillEllipse(in: disc(planet, planetR + sky * (1 - u)))
}

ctx.setFillColor(rgb(5, 7, 14))             // night side, the only near-black mass in the icon
ctx.fillEllipse(in: disc(planet, planetR))

ctx.drawRadialGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(255, 240, 200, 0.90), rgb(255, 196, 104, 0.34),
                                           rgb(255, 170, 70, 0)] as CFArray,
                                  locations: [0, 0.42, 1])!,
                       startCenter: sun, startRadius: sunR * 0.75, endCenter: sun, endRadius: sunR * 3.1,
                       options: [])
ctx.setFillColor(rgb(255, 253, 246))
ctx.fillEllipse(in: disc(sun, sunR))

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
guard let image = ctx.makeImage(),
      let sink = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(sink, image, nil)
CGImageDestinationFinalize(sink)
