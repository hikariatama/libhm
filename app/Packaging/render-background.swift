import AppKit
import ImageIO

struct Layout: Decodable {
    let content_width: Int
    let content_height: Int
    let title_bar_height: Int
    let icon_size: Int
    let text_size: Int
    let icon_locations: [String: [Int]]
}

let arguments = CommandLine.arguments
guard arguments.count == 5 else {
    fatalError("Usage: render-background.swift app-path layout.json banner@2x.png output-directory")
}
let layout = try JSONDecoder().decode(Layout.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
let sourceURL = URL(fileURLWithPath: arguments[3])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let pixels = CGImageSourceCreateImageAtIndex(source, 0, nil),
      pixels.width == layout.content_width * 2,
      pixels.height == layout.content_height * 2,
      let appIcon = NSImage(contentsOfFile: arguments[1] + "/Contents/Resources/AppIcon.icns") else {
    fatalError("Expected the unchanged 1308×844 (2×) banner and a built libhm.app")
}
let width = CGFloat(layout.content_width)
let height = CGFloat(layout.content_height)
let image = NSImage(cgImage: pixels, size: NSSize(width: width, height: height))
let output = URL(fileURLWithPath: arguments[4], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawLabel(_ value: String, centerX: CGFloat, top: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: CGFloat(layout.text_size)), .foregroundColor: NSColor.white
    ]
    let dimensions = (value as NSString).size(withAttributes: attributes)
    (value as NSString).draw(at: NSPoint(x: centerX - dimensions.width / 2,
        y: height - top - dimensions.height), withAttributes: attributes)
}

func render(scale: Int, preview: Bool) throws {
    // Only the preview includes window chrome. The actual image is 422 pt high;
    // a title-bar strip in the background would shift or crop the supplied art.
    let canvasHeight = height + (preview ? CGFloat(layout.title_bar_height) : 0)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale,
        pixelsHigh: Int(canvasHeight) * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: canvasHeight)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))

    // Composition preview only: Finder supplies live icons, labels and chrome.
    if preview {
        NSColor(white: 0.15, alpha: 1).setFill()
        NSRect(x: 0, y: height, width: width, height: CGFloat(layout.title_bar_height)).fill()
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white
        ]
        ("libhm" as NSString).draw(at: NSPoint(x: width / 2 - 16, y: height + 3), withAttributes: titleAttributes)
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: CGFloat(9 + index * 19), y: height + 6, width: 10, height: 10)).fill()
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            for (name, point) in layout.icon_locations {
                let size = CGFloat(layout.icon_size)
                let centerX = CGFloat(point[0])
                let centerY = CGFloat(point[1])
                let icon = name == "Applications" ? NSWorkspace.shared.icon(forFile: "/Applications") : appIcon
                icon.draw(in: NSRect(x: centerX - size / 2, y: height - centerY - size / 2,
                    width: size, height: size))
                drawLabel(name == "Applications" ? name : "libhm", centerX: centerX,
                    top: centerY + size / 2 + 8)
            }
        }
    }
    let filename = preview ? "installer-preview.png" : "background.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
}

// Preserve the supplied PNG byte-for-byte. tiffutil combines this original with
// the downsampled 1× image into a lossless, multi-resolution Finder background.
try FileManager.default.copyItem(at: sourceURL, to: output.appendingPathComponent("background@2x.png"))
try render(scale: 1, preview: false)
try render(scale: 2, preview: true)
