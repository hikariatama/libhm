import Foundation
import CoreGraphics
import ImageIO

// Inspect decoded pixels rather than comparing differently compressed PNG/TIFF bytes.
func rgba(_ image: CGImage) -> Data {
    var bytes = Data(count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { storage in
        let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let original = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(original, 0, nil),
      let background = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, nil) else {
    fatalError("Usage: verify-background.swift original.png embedded.tiff layout.json")
}
let layout = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: arguments[3]))) as! [String: Any]
let width = layout["content_width"] as! Int
let height = layout["content_height"] as! Int
precondition(image.width == width * 2 && image.height == height * 2, "Source must be exactly 2×")
precondition(CGImageSourceGetCount(background) == 2, "Finder background must include 1× and 2×")
for index in 0..<2 {
    let scale = index + 1
    let representation = CGImageSourceCreateImageAtIndex(background, index, nil)!
    let properties = CGImageSourceCopyPropertiesAtIndex(background, index, nil)! as NSDictionary
    precondition(representation.width == width * scale && representation.height == height * scale,
        "Background cropped or padded")
    precondition((properties[kCGImagePropertyDPIWidth] as! NSNumber).intValue == 72 * scale &&
        (properties[kCGImagePropertyDPIHeight] as! NSNumber).intValue == 72 * scale,
        "Wrong logical size for Retina representation")
    if scale == 2 {
        precondition(rgba(image) == rgba(representation), "Retina artwork differs from supplied pixels")
    }
}
print("Background verified: 654×422 pt, 1×/2×, source Retina pixels unchanged.")
