// Renders the app icon: a planet's lit limb with the sun standing just above it, which is the
// shot most of Apple's aerials open on. Bold solid shapes and no fine detail, because the same
// artwork has to read at 16 points in the Finder sidebar.
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

// The planet sits mostly below the frame, so only a shallow arc of it crosses the icon. Its
// centre and radius are what set the curvature: shrinking the radius bows the horizon harder.
let planet = px(0.5, -0.77), planetR = art.width * 1.15
let sun = px(0.5, 0.615), sunR = art.width * 0.115
let band = art.width * 0.10          // 1.3px of lit limb once the whole thing is 16 points

ctx.addPath(CGPath(roundedRect: art, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()

// night at the top warming into the atmosphere at the bottom. Kept well clear of black: the
// planet below is the only near-black in the icon, and at 16 points that gap is what reads.
ctx.drawLinearGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(30, 36, 66), rgb(48, 41, 76), rgb(126, 68, 42)] as CFArray,
                                  locations: [0, 0.52, 1])!,
                       start: px(0.5, 1.02), end: px(0.5, -0.02),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

ctx.drawRadialGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(255, 205, 132, 0.55), rgb(255, 186, 108, 0.13),
                                           rgb(255, 176, 96, 0)] as CFArray,
                                  locations: [0, 0.45, 1])!,
                       startCenter: sun, startRadius: 0, endCenter: sun, endRadius: art.width * 0.62,
                       options: [])

ctx.setFillColor(rgb(9, 11, 20))     // over the glow, so the bloom stops dead at the horizon
ctx.fillEllipse(in: disc(planet, planetR))

// the lit limb, brightest under the sun and cooling as it runs off both edges
ctx.saveGState()
ctx.addEllipse(in: disc(planet, planetR))
ctx.setLineWidth(band)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: space,
                                  colors: [rgb(226, 150, 86), rgb(255, 246, 226), rgb(226, 150, 86)] as CFArray,
                                  locations: [0, 0.5, 1])!,
                       start: px(-0.05, 0), end: px(1.05, 0),
                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

ctx.setFillColor(rgb(255, 247, 231))
ctx.fillEllipse(in: disc(sun, sunR))

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")
guard let image = ctx.makeImage(),
      let sink = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(sink, image, nil)
CGImageDestinationFinalize(sink)
