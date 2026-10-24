import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImagePipelineError: Error, CustomStringConvertible {
    case unreadable(String)
    case encodeFailed

    public var description: String {
        switch self {
        case .unreadable(let what): return "Can't read image: \(what)"
        case .encodeFailed: return "JPEG encoding failed"
        }
    }
}

public struct RenderedImage: Sendable {
    /// Exactly 3840×2160, sRGB, no metadata.
    public var jpeg: Data
    /// > 1 when the source region had fewer pixels than the panel (e.g. 1.6 = upscaled 1.6×).
    public var upscale: Double
}

/// Original photo → panel JPEG. Originals are never modified. See docs/SPEC.md §5.
public struct ImagePipeline: Sendable {
    /// Bump when output changes for the same input, to invalidate cached renders.
    public static let version = 1

    private let context: CIContext
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                      .cacheIntermediates: false])
    }

    /// Loads an image with its EXIF orientation applied. Color management uses the embedded profile.
    public func load(_ url: URL) throws -> CIImage {
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw ImagePipelineError.unreadable(url.lastPathComponent)
        }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    public func load(_ data: Data) throws -> CIImage {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw ImagePipelineError.unreadable("image data")
        }
        return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    public func render(_ url: URL, spec: RenderSpec) throws -> RenderedImage {
        try render(try load(url), spec: spec)
    }

    public func render(_ image: CIImage, spec: RenderSpec) throws -> RenderedImage {
        let panel = CGRect(x: 0, y: 0, width: Panel.width, height: Panel.height)
        var output: CIImage
        let upscale: Double
        switch spec.mode {
        case .crop(let rect):
            let region = pixelRect(rect, in: image.extent)
            output = scaled(image.cropped(to: region).clampedToExtent(), from: region, to: panel)
            upscale = Double(Panel.width) / region.width
        }
        if spec.sharpen {
            output = output.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.5, kCIInputIntensityKey: 0.4])
        }
        output = output.cropped(to: panel)
        guard let cg = context.createCGImage(output, from: panel, format: .RGBA8, colorSpace: sRGB) else {
            throw ImagePipelineError.encodeFailed
        }
        return RenderedImage(jpeg: try encodeJPEG(cg, quality: spec.jpegQuality), upscale: upscale)
    }

    /// Normalized top-left rect → pixel rect in Core Image's bottom-left space, nudged to exactly 16:9.
    func pixelRect(_ r: NormalizedRect, in extent: CGRect) -> CGRect {
        var w = r.width * extent.width
        var h = r.height * extent.height
        let cx = extent.minX + (r.x + r.width / 2) * extent.width
        let cy = extent.maxY - (r.y + r.height / 2) * extent.height
        if w / h > Panel.aspect { w = h * Panel.aspect } else { h = w / Panel.aspect }
        w = min(w, extent.width)
        h = min(h, extent.height)
        let x = min(max(cx - w / 2, extent.minX), extent.maxX - w)
        let y = min(max(cy - h / 2, extent.minY), extent.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Lanczos-resizes `region` of `image` onto `target`.
    private func scaled(_ image: CIImage, from region: CGRect, to target: CGRect) -> CIImage {
        let scale = target.height / region.height
        let aspect = (target.width / region.width) / scale
        let moved = image.transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = moved
        f.scale = Float(scale)
        f.aspectRatio = Float(aspect)
        return f.outputImage!.transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
    }

    /// JPEG with no EXIF/GPS/orientation metadata (only the sRGB profile).
    func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImagePipelineError.encodeFailed
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImagePipelineError.encodeFailed }
        return data as Data
    }

    /// Cache key: (source hash, render spec, pipeline version).
    public static func cacheKey(sourceSHA256: String, spec: RenderSpec) -> String {
        let text = "\(sourceSHA256)|\(spec.cacheDescription)|v\(version)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Rendered JPEGs on disk, regenerated from originals when missing. Default: ~/Library/Caches/Inframy/renders.
public struct RenderCache: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Inframy/renders")) {
        self.directory = directory
    }

    public func url(for key: String) -> URL { directory.appendingPathComponent("\(key).jpg") }

    /// Returns the cached render for `source` + `spec`, rendering and storing it if needed.
    public func render(_ source: URL, spec: RenderSpec, pipeline: ImagePipeline = ImagePipeline()) throws -> (url: URL, upscale: Double?) {
        let key = ImagePipeline.cacheKey(sourceSHA256: try ImagePipeline.sha256(of: source), spec: spec)
        let out = url(for: key)
        if FileManager.default.fileExists(atPath: out.path) { return (out, nil) }
        let rendered = try pipeline.render(source, spec: spec)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rendered.jpeg.write(to: out, options: .atomic)
        return (out, rendered.upscale)
    }
}
