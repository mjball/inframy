import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import InframyKit

struct ImagePipelineTests {
    let pipeline = ImagePipeline()

    // MARK: Output format

    @Test func outputIsExactlyPanelSizedSRGBJPEG() throws {
        let src = try TestImage.jpeg(width: 4032, height: 3024, colorSpace: .sRGB) { ctx, w, h in
            ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let image = try pipeline.load(src)
        let out = try pipeline.render(image, spec: RenderSpec(mode: .crop(.panelCrop(imageSize: image.extent.size))))
        let decoded = try TestImage.decode(out.jpeg)
        #expect(decoded.image.width == 3840 && decoded.image.height == 2160)
        #expect(decoded.image.colorSpace?.name == CGColorSpace.sRGB)
        #expect(decoded.type == UTType.jpeg.identifier)
    }

    @Test func metadataIsStripped() throws {
        let src = try TestImage.jpeg(width: 1920, height: 1080, colorSpace: .sRGB, properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.77, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone"],
        ]) { ctx, w, h in ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        #expect(try TestImage.decode(src).properties[kCGImagePropertyGPSDictionary as String] != nil)  // sanity
        let out = try pipeline.render(try pipeline.load(src), spec: RenderSpec(mode: .crop(.full)))
        let props = try TestImage.decode(out.jpeg).properties
        #expect(props[kCGImagePropertyGPSDictionary as String] == nil)
        #expect((props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFModel as String] == nil)
        #expect((props[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifUserComment as String] == nil)
        #expect((props[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1)
    }

    // MARK: Color

    @Test func displayP3IsConvertedNotReinterpreted() throws {
        // A saturated P3 color that changes noticeably in sRGB. If the pipeline ignored the profile, the output
        // would keep the raw P3 numbers.
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let components: [CGFloat] = [0.85, 0.35, 0.15, 1]
        let src = try TestImage.jpeg(width: 1920, height: 1080, colorSpace: .displayP3) { ctx, w, h in
            ctx.setFillColor(CGColor(colorSpace: p3, components: components)!)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let out = try pipeline.render(try pipeline.load(src), spec: RenderSpec(mode: .crop(.full), jpegQuality: 1))
        let pixel = try TestImage.pixel(out.jpeg, x: 1920, y: 1080)
        let expected = CGColor(colorSpace: p3, components: components)!
            .converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)!.components!
        for i in 0..<3 {
            #expect(abs(Double(pixel[i]) - expected[i] * 255) < 4, "channel \(i): \(pixel[i]) vs \(expected[i] * 255)")
        }
        // And it really did differ from the raw numbers (red goes out of sRGB gamut → clamps high).
        #expect(abs(Double(pixel[0]) - 0.85 * 255) > 10 || abs(Double(pixel[1]) - 0.35 * 255) > 10)
    }

    // MARK: Orientation and cropping

    @Test func exifOrientationIsApplied() throws {
        // Stored pixels: left half red, right half blue, 400×300. EXIF 6 = display rotated 90° clockwise,
        // so on screen the photo is 300×400 with red on TOP and blue on the bottom.
        let src = try TestImage.jpeg(width: 400, height: 300, colorSpace: .sRGB,
                                     properties: [kCGImagePropertyOrientation: 6]) { ctx, w, h in
            ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        }
        let image = try pipeline.load(src)
        #expect(image.extent.size == CGSize(width: 300, height: 400))
        let out = try pipeline.render(image, spec: RenderSpec(mode: .crop(.panelCrop(imageSize: image.extent.size))))
        let top = try TestImage.pixel(out.jpeg, x: 1920, y: 200)
        let bottom = try TestImage.pixel(out.jpeg, x: 1920, y: 1960)
        #expect(top[0] > 200 && top[2] < 60, "top should be red: \(top)")
        #expect(bottom[2] > 200 && bottom[0] < 60, "bottom should be blue: \(bottom)")
    }

    @Test func cropRectSelectsTheRightRegion() throws {
        // 3840×4320: top half green, bottom half magenta. Cropping the bottom 16:9 slice gives all magenta.
        let src = try TestImage.jpeg(width: 3840, height: 4320, colorSpace: .sRGB) { ctx, w, h in
            ctx.setFillColor(red: 1, green: 0, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))  // CG origin is bottom-left: this is the bottom
            ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
        }
        let out = try pipeline.render(try pipeline.load(src),
                                      spec: RenderSpec(mode: .crop(NormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5))))
        for (x, y) in [(10, 10), (1920, 1080), (3830, 2150)] {
            let p = try TestImage.pixel(out.jpeg, x: x, y: y)
            #expect(p[0] > 200 && p[1] < 60 && p[2] > 200, "(\(x),\(y)) should be magenta: \(p)")
        }
    }

    @Test func upscaleIsReported() throws {
        let src = try TestImage.jpeg(width: 1920, height: 1080, colorSpace: .sRGB) { ctx, w, h in
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let out = try pipeline.render(try pipeline.load(src), spec: RenderSpec(mode: .crop(.full)))
        #expect(abs(out.upscale - 2) < 0.001)
        #expect(try TestImage.decode(out.jpeg).image.width == 3840)
    }

    @Test func nonPanelRectIsNudgedTo16x9() {
        let extent = CGRect(x: 0, y: 0, width: 4000, height: 3000)
        let r = pipeline.pixelRect(NormalizedRect(x: 0, y: 0, width: 1, height: 1), in: extent)
        #expect(abs(r.width / r.height - Panel.aspect) < 0.0001)
        #expect(r.width == 4000)
        #expect(extent.contains(r))
    }

    @Test func panelCropGeometry() {
        let wide = NormalizedRect.panelCrop(imageSize: CGSize(width: 4000, height: 1000))
        #expect(wide.height == 1 && abs(wide.width - (16.0 / 9.0) / 4) < 1e-9 && abs(wide.x - (1 - wide.width) / 2) < 1e-9)
        let tall = NormalizedRect.panelCrop(imageSize: CGSize(width: 3000, height: 4000))
        #expect(tall.width == 1 && abs(tall.height - 0.75 / (16.0 / 9.0)) < 1e-9)
        // A center near the edge is clamped so the frame stays inside the image.
        let edge = NormalizedRect.panelCrop(imageSize: CGSize(width: 3000, height: 4000), center: CGPoint(x: 0.5, y: 0.02))
        #expect(edge.y == 0)
    }

    // MARK: Cache

    @Test func cacheKeyDependsOnSourceSpecAndVersion() {
        let a = ImagePipeline.cacheKey(sourceSHA256: "abc", spec: RenderSpec(mode: .crop(.full)))
        #expect(a == ImagePipeline.cacheKey(sourceSHA256: "abc", spec: RenderSpec(mode: .crop(.full))))
        #expect(a != ImagePipeline.cacheKey(sourceSHA256: "abd", spec: RenderSpec(mode: .crop(.full))))
        #expect(a != ImagePipeline.cacheKey(sourceSHA256: "abc", spec: RenderSpec(mode: .crop(NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)))))
        #expect(a != ImagePipeline.cacheKey(sourceSHA256: "abc", spec: RenderSpec(mode: .crop(.full), sharpen: true)))
    }

    @Test func renderCacheReusesRenders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("photo.jpg")
        try TestImage.jpeg(width: 1920, height: 1080, colorSpace: .sRGB) { ctx, w, h in
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }.write(to: src)
        let cache = RenderCache(directory: dir.appendingPathComponent("renders"))
        let first = try cache.render(src, spec: RenderSpec(mode: .crop(.full)))
        #expect(first.upscale != nil)
        let second = try cache.render(src, spec: RenderSpec(mode: .crop(.full)))
        #expect(second.url == first.url && second.upscale == nil)  // nil = served from cache
    }

    // MARK: Crop suggestion

    @Test func suggestionIsAPointNotACrop() throws {
        // A plain image gives no suggestion (or one inside the image); either way it's only a starting point.
        let src = try TestImage.jpeg(width: 2000, height: 1500, colorSpace: .sRGB) { ctx, w, h in
            ctx.setFillColor(gray: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(red: 1, green: 0.1, blue: 0.1, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: w * 0.75, y: h * 0.4, width: w * 0.15, height: h * 0.2))
        }
        let image = try pipeline.load(src)
        if let c = CropSuggestion.center(for: image) {
            #expect((0...1).contains(c.x) && (0...1).contains(c.y))
        }
        let frame = CropSuggestion.initialFrame(for: image)
        #expect(abs(frame.width * 2000 / (frame.height * 1500) - Panel.aspect) < 0.001)
    }
}

enum TestImage {
    enum Space { case sRGB, displayP3 }

    static func jpeg(width: Int, height: Int, colorSpace: Space, properties: [CFString: Any] = [:],
                     draw: (CGContext, CGFloat, CGFloat) -> Void) throws -> Data {
        let cs = CGColorSpace(name: colorSpace == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        draw(ctx, CGFloat(width), CGFloat(height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = 1.0
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ImagePipelineError.encodeFailed }
        return data as Data
    }

    static func decode(_ data: Data) throws -> (image: CGImage, properties: [String: Any], type: String) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ImagePipelineError.unreadable("test") }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
        return (image, props, CGImageSourceGetType(src) as String? ?? "")
    }

    /// RGB at (x, y) with a top-left origin, as stored (sRGB 8-bit).
    static func pixel(_ data: Data, x: Int, y: Int) throws -> [UInt8] {
        let image = try decode(data).image
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return Array(px.prefix(3))
    }
}
