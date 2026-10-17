#!/usr/bin/env swift
// app-icon.swift: draws Kobi's app icon into app/Kobi/Assets.xcassets/AppIcon.appiconset.
// The same dotted sphere as the menu bar icon (MenuIcon.swift), in Orb White on the
// near-black ground from DESIGN.md. The art fills the square: macOS masks it to its icon shape.
//
//   swift scripts/app-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let set = root.appendingPathComponent("app/Kobi/Assets.xcassets/AppIcon.appiconset")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = CGPoint(x: s / 2, y: s / 2)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Ground: raised at the middle, falling to ground at the edges.
    ctx.setFillColor(rgb(0x0b0d12))
    ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
    let ground = CGGradient(colorsSpace: space, colors: [rgb(0x161a24), rgb(0x0b0d12)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(ground, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.62, options: [])

    // The orb's soft glow.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xf2f5ff, 0.16), rgb(0xf2f5ff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.4, options: [])

    // Points on a tilted sphere, nearer ones larger and brighter. Small sizes keep the
    // menu bar icon's 46 points so the dots stay apart.
    let n = px <= 64 ? 46 : 150
    let radius = s * 0.3
    let unit = s * (px <= 64 ? 0.042 : 0.04) * (46.0 / Double(n)).squareRoot()
    let golden = Double.pi * (3 - 5.0.squareRoot()), tilt = 0.5
    var dots: [(p: CGPoint, r: CGFloat, depth: Double)] = []
    for i in 0..<n {
        let y = 1 - (Double(i) + 0.5) / Double(n) * 2
        let r = (1 - y * y).squareRoot(), phi = Double(i) * golden
        let x = cos(phi) * r, z = sin(phi) * r
        let y1 = y * cos(tilt) - z * sin(tilt), z1 = y * sin(tilt) + z * cos(tilt)
        let depth = (z1 + 1) / 2
        dots.append((CGPoint(x: c.x + CGFloat(x) * radius, y: c.y + CGFloat(y1) * radius),
                     CGFloat(0.42 + 0.5 * depth) * unit, depth))
    }
    // Far dots first, so near ones sit on top.
    for d in dots.sorted(by: { $0.depth < $1.depth }) {
        ctx.setFillColor(rgb(0xf2f5ff, CGFloat(0.22 + 0.78 * d.depth)))
        ctx.fillEllipse(in: CGRect(x: d.p.x - d.r, y: d.p.y - d.r, width: d.r * 2, height: d.r * 2))
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

// macOS sizes: each point size at 1x and 2x.
var images: [String] = []
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try draw(pt * scale).write(to: set.appendingPathComponent(name))
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(pt)x\(pt)" }
        """)
    }
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try """
{
  "info" : { "author" : "xcode", "version" : 1 }
}

""".write(to: set.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(set.path)")
