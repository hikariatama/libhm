import Foundation
import MapKit

/// MapKit can inset its camera for native window chrome. Recover the full view's
/// Mercator rectangle from its public coordinate conversion, not an assumed center.
enum MapCanvasProjection {
    static func rect(bounds: CGRect, center: MKMapPoint, step: MKMapSize,
                     projectedCenter: CGPoint, projectedX: CGPoint, projectedY: CGPoint, flipped: Bool) -> MKMapRect? {
        let sx = (projectedX.x - projectedCenter.x) / step.width
        let sy = (projectedY.y - projectedCenter.y) / step.height
        guard bounds.width > 0, bounds.height > 0, sx.isFinite, sy.isFinite, sx > 0, sy != 0 else { return nil }
        let top = flipped ? bounds.minY : bounds.maxY
        let x = center.x + (bounds.minX - projectedCenter.x) / sx
        let y = center.y + (top - projectedCenter.y) / sy
        let width = bounds.width / sx, height = bounds.height / abs(sy)
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        return MKMapRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
extension MKMapView {
    var canvasMapRect: MKMapRect {
        let reference = visibleMapRect
        let center = MKMapPoint(x: reference.midX, y: reference.midY)
        let step = MKMapSize(width: min(reference.width / 4, MKMapRect.world.width / 8),
                             height: min(reference.height / 4, MKMapRect.world.height / 8))
        guard step.width > 0, step.height > 0 else { return reference }
        return MapCanvasProjection.rect(bounds: bounds, center: center, step: step,
            projectedCenter: convert(center.coordinate, toPointTo: self),
            projectedX: convert(MKMapPoint(x: center.x + step.width, y: center.y).coordinate, toPointTo: self),
            projectedY: convert(MKMapPoint(x: center.x, y: center.y + step.height).coordinate, toPointTo: self),
            flipped: isFlipped) ?? reference
    }
}

/// Overlay frames use SwiftUI's top-left origin, in points rather than Retina pixels.
struct MapViewportLayout: Equatable {
    var size: CGSize = .zero
    var panel: CGRect?
    var controls: CGRect?
    var legend: CGRect?
    var galleryExpanded = true

    static let overlap: CGFloat = 12

    var screenRect: CGRect {
        let bounds = CGRect(origin: .zero, size: size)
        guard size.width > 0, size.height > 0 else { return .zero }
        let left = galleryExpanded ? panel?.maxX ?? 0 : 0
        let right = controls?.minX ?? bounds.maxX
        let top = galleryExpanded
            ? min(panel?.minY ?? 0, controls?.minY ?? 0)
            : panel?.maxY ?? 0
        let bottom = min(legend?.minY ?? bounds.maxY, galleryExpanded ? panel?.maxY ?? bounds.maxY : bounds.maxY)
        let free = CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
        return free.insetBy(dx: -Self.overlap, dy: -Self.overlap).intersection(bounds)
    }

    func galleryRect(in camera: MKMapRect) -> MKMapRect {
        guard size.width > 0, size.height > 0 else { return camera }
        let rect = screenRect
        // Rotation and pitch are disabled: screen fractions map directly to Mercator fractions.
        // Keep unwrapped x values so SpatialIndex can query across the date line.
        return MKMapRect(x: camera.minX + rect.minX / size.width * camera.width,
                         y: camera.minY + rect.minY / size.height * camera.height,
                         width: rect.width / size.width * camera.width,
                         height: rect.height / size.height * camera.height)
    }
}
