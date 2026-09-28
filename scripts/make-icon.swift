// Draws the AeriaLite mark: a crescent moon in the lower left, open toward the upper right, with a
// four-pointed star sitting in that opening. The star is an astroid (the Steelers' hypocycloid),
// two wide to three tall. Writes the app icon, white on a flat field, and the menu bar image,
// black on transparent for AppKit to use as a template.
//
//     make-icon <icon.png> <menu.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpaceCreateDeviceRGB()

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

/// The mark in a unit square, y up. The bite circle sits up and right of the moon, which is what
/// points the crescent's opening that way; the star goes in the middle of that opening.
func mark() -> CGPath {
    let moon = (x: 0.39, y: 0.39, r: 0.37)
    let bite = (x: 0.552, y: 0.552, r: 0.333)   // 0.23 apart: 0.26 thick at the belly
    let disc = CGPath(ellipseIn: CGRect(x: moon.x - moon.r, y: moon.y - moon.r,
                                        width: moon.r * 2, height: moon.r * 2), transform: nil)
    let hole = CGPath(ellipseIn: CGRect(x: bite.x - bite.r, y: bite.y - bite.r,
                                        width: bite.r * 2, height: bite.r * 2), transform: nil)
    let path = CGMutablePath()
    path.addPath(disc.subtracting(hole))

    // x = w cos³t, y = h sin³t: four cusps, sides curving in, 2:3 as the Steelers draw theirs
    let star = (x: 0.78, y: 0.72, w: 0.17, h: 0.255)
    let steps = 720
    for i in 0..<steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let p = CGPoint(x: star.x + star.w * pow(cos(t), 3), y: star.y + star.h * pow(sin(t), 3))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

func canvas(_ side: Int) -> CGContext {
    CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ ctx: CGContext, _ path: String) {
    guard let image = ctx.makeImage(),
          let sink = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)
    else { FileHandle.standardError.write(Data("make-icon: cannot write \(path)\n".utf8)); exit(1) }
    CGImageDestinationAddImage(sink, image, nil)
    CGImageDestinationFinalize(sink)
}

/// Fills the mark into `box`, which is where the unit square lands.
func draw(_ ctx: CGContext, in box: CGRect, _ color: CGColor) {
    var place = CGAffineTransform(translationX: box.minX, y: box.minY)
        .scaledBy(x: box.width, y: box.height)
    guard let path = mark().copy(using: &place) else { return }
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

let args = CommandLine.arguments
let iconPath = args.count > 1 ? args[1] : "icon.png"
let menuPath = args.count > 2 ? args[2] : "menu.png"

// the macOS icon grid: 824 of artwork on 1024, corners at 22.4%
let side = 1024.0, inset = 100.0, radius = 185.0
let art = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let icon = canvas(Int(side))
icon.addPath(CGPath(roundedRect: art, cornerWidth: radius, cornerHeight: radius, transform: nil))
icon.clip()
icon.setFillColor(rgb(24, 27, 42))
icon.fill(art)
draw(icon, in: art.insetBy(dx: art.width * 0.17, dy: art.height * 0.17), rgb(255, 255, 255))
write(icon, iconPath)

// 17pt in the menu bar at 2x; AppKit takes the shape from alpha and supplies the colour itself
let menu = canvas(34)
draw(menu, in: CGRect(x: 0, y: 0, width: 34, height: 34), rgb(0, 0, 0))
write(menu, menuPath)
