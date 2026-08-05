// Renders the app icon from scripts/astronaut.png: the helmet silhouette, filled in the shell
// colour over a flat field. Nothing here draws the helmet, it only recolours and scales the
// source, so the shape is whatever that file says it is.
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
let field = (r: 24.0, g: 27.0, b: 42.0), shell = (r: 255.0, g: 255.0, b: 255.0)

let art = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)

let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : "icon.png")
let source = URL(fileURLWithPath: args.count > 2 ? args[2]
                                : URL(fileURLWithPath: args[0]).deletingLastPathComponent()
                                     .appendingPathComponent("astronaut.png").path)
guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
      let ref = CGImageSourceCreateImageAtIndex(reader, 0, nil)
else { FileHandle.standardError.write(Data("make-icon: cannot read \(source.path)\n".utf8)); exit(1) }

/// Box blur, three passes, which lands close enough to a Gaussian and keeps this to running sums.
func blur(_ input: [Double], _ m: Int, _ r: Int) -> [Double] {
    var a = input, b = [Double](repeating: 0, count: m * m)
    let width = Double(2 * r + 1)
    func clamp(_ i: Int) -> Int { min(max(i, 0), m - 1) }
    for _ in 0..<3 {
        for y in 0..<m {
            var sum = (-r...r).reduce(0.0) { $0 + a[y * m + clamp($1)] }
            for x in 0..<m {
                b[y * m + x] = sum / width
                sum += a[y * m + clamp(x + r + 1)] - a[y * m + clamp(x - r)]
            }
        }
        for x in 0..<m {
            var sum = (-r...r).reduce(0.0) { $0 + b[clamp($1) * m + x] }
            for y in 0..<m {
                a[y * m + x] = sum / width
                sum += b[clamp(y + r + 1) * m + x] - b[clamp(y - r) * m + x]
            }
        }
    }
    return a
}

let m = Int(art.width.rounded())
var scratch = [UInt8](repeating: 0, count: m * m * 4)
scratch.withUnsafeMutableBytes { buffer in
    let up = CGContext(data: buffer.baseAddress, width: m, height: m, bitsPerComponent: 8,
                       bytesPerRow: m * 4, space: space,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    up.interpolationQuality = .high
    up.draw(ref, in: CGRect(x: 0, y: 0, width: Double(m), height: Double(m)))
}

// The source is black on transparent, so its alpha is the coverage. A 24px source scaled 34x puts
// every source pixel on screen as a stair; blurring by about half a source pixel before the
// threshold is what rounds those off. Much past that and the ear pods melt into the shell.
let ramp = blur((0..<(m * m)).map { Double(scratch[$0 * 4 + 3]) / 255 }, m, m / 60)

var pixels = [UInt8](repeating: 0, count: m * m * 4)
for i in 0..<(m * m) {
    let t = min(max((ramp[i] - 0.46) / 0.08, 0), 1)
    let a = t * t * (3 - 2 * t)                             // smoothstep, so the edge antialiases
    pixels[i * 4 + 0] = UInt8((shell.r * a).rounded())      // premultiplied, matching the context
    pixels[i * 4 + 1] = UInt8((shell.g * a).rounded())
    pixels[i * 4 + 2] = UInt8((shell.b * a).rounded())
    pixels[i * 4 + 3] = UInt8((255 * a).rounded())
}
let helmet = pixels.withUnsafeMutableBytes { buffer -> CGImage in
    CGContext(data: buffer.baseAddress, width: m, height: m, bitsPerComponent: 8, bytesPerRow: m * 4,
              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
}

ctx.addPath(CGPath(roundedRect: art, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.clip()
ctx.setFillColor(rgb(field.r, field.g, field.b))
ctx.fill(art.insetBy(dx: -inset, dy: -inset))
ctx.draw(helmet, in: art)

guard let image = ctx.makeImage(),
      let sink = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(sink, image, nil)
CGImageDestinationFinalize(sink)
