import CoreGraphics
import Foundation

/// The crop editor's model: a fixed 16:9 frame with the image moving and scaling under it.
/// `zoom` 1 = the largest 16:9 area of the image; `center` is normalized (top-left origin).
public struct CropGeometry: Sendable, Equatable {
    public let imageSize: CGSize
    public private(set) var zoom: Double
    public private(set) var center: CGPoint

    /// Smallest crop allowed, in source pixels wide: the panel's width, so nothing is ever upscaled.
    public static let minimumCropWidth = Double(Panel.width)

    public init(imageSize: CGSize, center: CGPoint = CGPoint(x: 0.5, y: 0.5), zoom: Double = 1) {
        self.imageSize = imageSize
        self.zoom = 1
        self.center = center
        setZoom(zoom)
        clampCenter()
    }

    /// Starts from an existing crop rect.
    public init(imageSize: CGSize, rect: NormalizedRect) {
        self.init(imageSize: imageSize)
        zoom = max(1, base.width / max(rect.width, 1e-6))
        center = CGPoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        setZoom(zoom)
        clampCenter()
    }

    /// The zoom-1 frame size, normalized.
    var base: NormalizedRect { .panelCrop(imageSize: imageSize) }

    public var maxZoom: Double {
        max(1, base.width * imageSize.width / Self.minimumCropWidth)
    }

    public var rect: NormalizedRect {
        let w = base.width / zoom, h = base.height / zoom
        return NormalizedRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    /// Panel pixels per source pixel; > 1 means upscaling (show a quality warning).
    public var upscale: Double { Double(Panel.width) / (rect.width * imageSize.width) }

    public mutating func setZoom(_ z: Double) {
        zoom = min(max(z, 1), maxZoom)
        clampCenter()
    }

    /// Zooms by `factor`, keeping the image point under `anchor` (normalized within the frame, 0…1) in place.
    public mutating func zoom(by factor: Double, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let before = rect
        let imagePoint = CGPoint(x: before.x + anchor.x * before.width, y: before.y + anchor.y * before.height)
        setZoom(zoom * factor)
        let after = rect
        center = CGPoint(x: imagePoint.x - (anchor.x - 0.5) * after.width,
                         y: imagePoint.y - (anchor.y - 0.5) * after.height)
        clampCenter()
    }

    /// Drags the image by a delta in view points, given the frame's on-screen size. Dragging the image right
    /// shows more of its left side.
    public mutating func pan(by delta: CGSize, frameSize: CGSize) {
        let r = rect
        center.x -= delta.width / frameSize.width * r.width
        center.y -= delta.height / frameSize.height * r.height
        clampCenter()
    }

    /// Nudges by a fraction of the frame (arrow keys).
    public mutating func nudge(dx: Double, dy: Double) {
        let r = rect
        center.x += dx * r.width
        center.y += dy * r.height
        clampCenter()
    }

    private mutating func clampCenter() {
        let w = base.width / zoom, h = base.height / zoom
        center.x = min(max(center.x, w / 2), 1 - w / 2)
        center.y = min(max(center.y, h / 2), 1 - h / 2)
    }
}
