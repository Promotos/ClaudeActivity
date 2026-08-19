// Generates Resources/AppIcon.icns — the app icon, drawn from code so it stays
// reproducible and tweakable without a binary editor.
//
//   swift make-icon.swift
//
// The motif matches the menu bar indicator: two stacked triangles, outbound on
// top, inbound below. The shapes are plain Bezier paths on purpose — SF Symbols
// must not be used in app icons under Apple's license terms.

import AppKit
import Foundation

enum Icon {
    /// macOS icons sit on a canvas with a margin around the rounded square.
    static let contentRatio: CGFloat = 0.806
    static let cornerRatio: CGFloat = 0.225

    static let topColor = NSColor(srgbRed: 0.36, green: 0.56, blue: 0.99, alpha: 1)
    static let bottomColor = NSColor(srgbRed: 0.09, green: 0.20, blue: 0.58, alpha: 1)

    /// Draws the icon at an arbitrary edge length, in points of the current context.
    static func draw(size: CGFloat) {
        let canvas = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.clear.setFill()
        canvas.fill()

        // Rounded square with the standard macOS margin.
        let side = size * contentRatio
        let plate = NSRect(x: (size - side) / 2, y: (size - side) / 2,
                           width: side, height: side)
        let radius = side * cornerRatio
        let shape = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

        NSGradient(starting: bottomColor, ending: topColor)?.draw(in: shape, angle: 90)

        // Two triangles, mirrored around the centre, sized relative to the plate.
        let centerX = plate.midX
        let centerY = plate.midY
        // The gap has to survive the 16 px rendition, otherwise the two triangles
        // merge into a single diamond.
        let arrowWidth = side * 0.44
        let arrowHeight = side * 0.225
        let gap = side * 0.12

        NSColor.white.setFill()
        triangle(apex: NSPoint(x: centerX, y: centerY + gap / 2 + arrowHeight),
                 baseY: centerY + gap / 2, width: arrowWidth).fill()
        triangle(apex: NSPoint(x: centerX, y: centerY - gap / 2 - arrowHeight),
                 baseY: centerY - gap / 2, width: arrowWidth).fill()
    }

    private static func triangle(apex: NSPoint, baseY: CGFloat, width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: apex)
        path.line(to: NSPoint(x: apex.x - width / 2, y: baseY))
        path.line(to: NSPoint(x: apex.x + width / 2, y: baseY))
        path.close()
        return path
    }

    /// Renders one PNG at an exact pixel size; every size is drawn fresh rather
    /// than scaled, so the edges stay crisp at 16 px.
    static func png(pixels: Int) -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { fatalError("could not allocate a bitmap of \(pixels) px") }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(size: CGFloat(pixels))
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            fatalError("could not encode PNG at \(pixels) px")
        }
        return data
    }
}

// The set of sizes `iconutil` expects.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",    32),
    ("icon_32x32",      32), ("icon_32x32@2x",    64),
    ("icon_128x128",   128), ("icon_128x128@2x", 256),
    ("icon_256x256",   256), ("icon_256x256@2x", 512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let url = iconset.appendingPathComponent("\(variant.name).png")
    try Icon.png(pixels: variant.pixels).write(to: url)
    print("  \(variant.name).png  (\(variant.pixels) px)")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

try? FileManager.default.removeItem(at: iconset)
print("wrote \(output.path)")
