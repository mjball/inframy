import CoreGraphics
import CoreImage
import Foundation

/// 64-bit difference hash (dHash): shrink to 9×8 grayscale, one bit per "is this pixel brighter than its right
/// neighbour". Robust to resizing, recompression and small color shifts, which is exactly the gap between a
/// library render and the TV's thumbnail of it.
public enum PerceptualHash {
    public static func dHash(_ image: CGImage) -> UInt64 {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    public static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// Hash of what a library photo looks like on the panel: its crop (or blur-fit) at small size.
    /// Cheap enough to run on every library photo: renders from a 640 px preview, not the original.
    public static func panelHash(of photo: LibraryPhoto, store: LibraryStore) -> UInt64? {
        guard let spec = photo.renderSpec, let url = store.url(for: photo),
              let preview = LibraryStore.thumbnail(of: url, maxPixel: 640) else { return nil }
        let ci = CIImage(cgImage: preview)
        let small: CIImage
        switch spec.mode {
        case .crop(let rect):
            let r = ImagePipeline().pixelRect(rect, in: ci.extent)
            small = ci.cropped(to: r)
        case .fitWithBlur:
            // The blurred fill dominates the edges; hashing the whole photo letterboxed is close enough.
            small = ci
        }
        guard let cg = CIContext().createCGImage(small, from: small.extent) else { return nil }
        return dHash(cg)
    }
}

/// Proposes links between TV items Inframy doesn't know about and library photos (SPEC §6 "adoption").
/// Proposals only: Matt confirms each link, and unknown items are never deleted automatically.
public enum Adoption {
    public struct Proposal: Sendable, Equatable {
        public let contentID: String
        public let photoID: UUID
        public let distance: Int
    }

    /// Distances up to this count as "the same picture". dHash of a re-encoded, resized copy is typically 0–6;
    /// unrelated photos land around 32. Tune on real data.
    public static let defaultThreshold = 10

    /// Best one-to-one matches under `threshold`, closest first.
    public static func propose(tvHashes: [String: UInt64], photoHashes: [UUID: UInt64],
                               threshold: Int = defaultThreshold) -> [Proposal] {
        var candidates: [Proposal] = []
        for (cid, th) in tvHashes {
            for (pid, ph) in photoHashes {
                let d = PerceptualHash.distance(th, ph)
                if d <= threshold { candidates.append(Proposal(contentID: cid, photoID: pid, distance: d)) }
            }
        }
        candidates.sort { ($0.distance, $0.contentID) < ($1.distance, $1.contentID) }
        var usedTV = Set<String>(), usedPhoto = Set<UUID>()
        var result: [Proposal] = []
        for c in candidates where !usedTV.contains(c.contentID) && !usedPhoto.contains(c.photoID) {
            usedTV.insert(c.contentID)
            usedPhoto.insert(c.photoID)
            result.append(c)
        }
        return result
    }

    /// Records a confirmed link: the photo is now "on the TV" as `contentID`, as rendered with its current choice.
    public static func link(_ photo: LibraryPhoto, to contentID: String) -> LibraryPhoto {
        var p = photo
        p.tvContentID = contentID
        p.uploadedRenderKey = p.renderKey
        return p
    }
}
