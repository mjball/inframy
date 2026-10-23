import CoreImage
import Foundation
import Vision

/// Suggests where to *start* the 16:9 frame in the crop editor. Matt always chooses the crop himself; this is
/// never applied on its own. Faces first (with a little headroom), then Vision's attention-based saliency.
public enum CropSuggestion {
    /// Suggested center of the crop, normalized with a top-left origin, or nil if nothing stands out
    /// (the editor then starts centered).
    public static func center(for image: CIImage, context: CIContext = CIContext()) -> CGPoint? {
        // Vision doesn't need full resolution.
        let maxSide: CGFloat = 1024
        let scale = min(1, maxSide / max(image.extent.width, image.extent.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(small, from: small.extent) else { return nil }

        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([faces, saliency])

        // Vision boxes are normalized with a bottom-left origin.
        if let faceBoxes = faces.results?.map(\.boundingBox), !faceBoxes.isEmpty {
            let union = faceBoxes.dropFirst().reduce(faceBoxes[0]) { $0.union($1) }
            // Aim a bit above the faces' center so the frame keeps headroom instead of cutting at the chin.
            return CGPoint(x: union.midX, y: 1 - union.midY - union.height * 0.15)
        }
        if let objects = saliency.results?.first?.salientObjects, !objects.isEmpty {
            let union = objects.dropFirst().reduce(objects[0].boundingBox) { $0.union($1.boundingBox) }
            return CGPoint(x: union.midX, y: 1 - union.midY)
        }
        return nil
    }

    public static func center(for url: URL) throws -> CGPoint? {
        center(for: try ImagePipeline().load(url))
    }

    /// The editor's starting frame: the largest 16:9 rect around the suggested center (or the image center).
    public static func initialFrame(for image: CIImage) -> NormalizedRect {
        let size = image.extent.size
        guard let c = center(for: image) else { return .panelCrop(imageSize: size) }
        return .panelCrop(imageSize: size, center: c)
    }
}
