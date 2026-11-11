// Makes AgentTerm's app icon and writes it where the two apps expect it:
//   iOS/AgentTerm/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//   assets/AppIcon.icns (through an .iconset and iconutil)
// Run from the repository root: swift scripts/make-icons.swift
//
// The picture is assets/icon-source.png when that file is there: a square,
// full-bleed image, 1024 pixels or more. Without it the icon is drawn here.
import AppKit

/// The picture itself, drawn into a square of the given size. On the Mac the
/// icon is a rounded tile with a margin, as the system's own are; on the
/// iPhone it fills the square and the system rounds it.
let source: CGImage? = NSImage(contentsOfFile: "assets/icon-source.png")?.cgImage(forProposedRect: nil, context: nil, hints: nil)

func draw(size: CGFloat, forMac: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    let inset = forMac ? size * 0.098 : 0
    let tile = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = forMac ? tile.width * 0.2237 : 0
    let shape = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    if forMac {
        context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(shape)
        context.setFillColor(CGColor(red: 0.07, green: 0.075, blue: 0.1, alpha: 1))
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
    }
    context.addPath(shape)
    context.clip()
    if let source {
        // The artwork fills the tile; on the Mac the tile's shape crops it.
        context.interpolationQuality = .high
        context.draw(source, in: tile)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    let colors = [CGColor(red: 0.13, green: 0.14, blue: 0.20, alpha: 1), CGColor(red: 0.055, green: 0.058, blue: 0.08, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])

    let unit = tile.width
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + unit * x, y: tile.minY + unit * y) }

    // One dot for each agent, in the colors the app gives them.
    let dots: [CGColor] = [
        CGColor(red: 0.87, green: 0.53, blue: 0.36, alpha: 1), CGColor(red: 0.40, green: 0.78, blue: 0.72, alpha: 1),
        CGColor(red: 0.45, green: 0.62, blue: 0.98, alpha: 1), CGColor(red: 0.72, green: 0.56, blue: 0.96, alpha: 1),
    ]
    for (index, color) in dots.enumerated() {
        let center = point(0.20 + CGFloat(index) * 0.095, 0.79)
        let r = unit * 0.03
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
    }

    // The prompt: a chevron and the cursor waiting after it.
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setLineWidth(unit * 0.085)
    context.setStrokeColor(CGColor(red: 0.93, green: 0.94, blue: 0.97, alpha: 1))
    context.move(to: point(0.22, 0.60))
    context.addLine(to: point(0.42, 0.43))
    context.addLine(to: point(0.22, 0.26))
    context.strokePath()
    context.setStrokeColor(CGColor(red: 0.45, green: 0.62, blue: 0.98, alpha: 1))
    context.move(to: point(0.54, 0.26))
    context.addLine(to: point(0.78, 0.26))
    context.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep, opaque: Bool) -> Data {
    guard opaque else { return rep.representation(using: .png, properties: [:])! }
    // The App Store refuses an icon with an alpha channel, so the picture
    // is copied into a bitmap that has none.
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil, width: rep.pixelsWide, height: rep.pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

let fm = FileManager.default
let iosFolder = "iOS/AgentTerm/Assets.xcassets/AppIcon.appiconset"
try fm.createDirectory(atPath: iosFolder, withIntermediateDirectories: true)
try png(draw(size: 1024, forMac: false), opaque: true).write(to: URL(fileURLWithPath: iosFolder + "/icon-1024.png"))
try #"{"images":[{"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}"#
    .write(toFile: iosFolder + "/Contents.json", atomically: true, encoding: .utf8)
try #"{"info":{"author":"xcode","version":1}}"#.write(toFile: "iOS/AgentTerm/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)

let iconset = NSTemporaryDirectory() + "AgentTerm.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try png(draw(size: CGFloat(points * scale), forMac: true), opaque: false).write(to: URL(fileURLWithPath: iconset + "/" + name))
}
try fm.createDirectory(atPath: "assets", withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "assets/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(atPath: iconset)
print(iconutil.terminationStatus == 0 ? "Wrote the iPhone icon and assets/AppIcon.icns from \(source == nil ? "the drawing in this script" : "assets/icon-source.png")" : "iconutil failed")
