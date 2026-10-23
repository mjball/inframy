import CoreGraphics
import Foundation

/// The Frame's panel.
public enum Panel {
    public static let width = 3840
    public static let height = 2160
    public static let aspect = Double(width) / Double(height)
}

/// A rect in 0…1 coordinates of the *oriented* image (EXIF orientation applied), origin top-left.
/// Stored instead of pixels so crops survive re-rendering from originals at any size.
public struct NormalizedRect: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    /// The largest 16:9 rect for an image of `size`, centered on `center` (normalized, top-left origin) and
    /// kept inside the image.
    public static func panelCrop(imageSize size: CGSize, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> NormalizedRect {
        let imageAspect = size.width / size.height
        var w = 1.0, h = 1.0
        if imageAspect > Panel.aspect {
            w = Panel.aspect / imageAspect  // wider than 16:9: full height
        } else {
            h = imageAspect / Panel.aspect  // taller: full width
        }
        let x = min(max(center.x - w / 2, 0), 1 - w)
        let y = min(max(center.y - h / 2, 0), 1 - h)
        return NormalizedRect(x: x, y: y, width: w, height: h)
    }
}

/// How a photo becomes a panel image.
public enum RenderMode: Codable, Sendable, Equatable, Hashable {
    /// A 16:9 slice of the photo.
    case crop(NormalizedRect)
    /// The whole photo, sharp, over a blurred and darkened copy of itself (for portraits and squares).
    case fitWithBlur
}

public struct RenderSpec: Codable, Sendable, Equatable, Hashable {
    public var mode: RenderMode
    /// Light unsharp mask after resizing. Off by default; judge it on the actual TV.
    public var sharpen: Bool
    public var jpegQuality: Double

    public init(mode: RenderMode, sharpen: Bool = false, jpegQuality: Double = 0.9) {
        self.mode = mode
        self.sharpen = sharpen
        self.jpegQuality = jpegQuality
    }

    /// Stable description used in cache keys.
    var cacheDescription: String {
        let m: String
        switch mode {
        case .crop(let r): m = String(format: "crop:%.6f,%.6f,%.6f,%.6f", r.x, r.y, r.width, r.height)
        case .fitWithBlur: m = "fitblur"
        }
        return "\(m);sharpen=\(sharpen);q=\(jpegQuality)"
    }
}
