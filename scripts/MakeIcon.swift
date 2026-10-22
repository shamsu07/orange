import AppKit
import Foundation
import OrangeArtwork

@main struct OrangeIconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Pass an output directory") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Orange.iconset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let edge = CGFloat(pixels)
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot allocate icon") }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                OrangeIcon.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge))
                NSGraphicsContext.restoreGraphicsState()
                let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
                try png.write(to: directory.appendingPathComponent(filename))
            }
        }
    }
}
