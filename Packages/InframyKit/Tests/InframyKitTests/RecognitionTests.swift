import CoreGraphics
import Foundation
import Testing
@testable import InframyKit

struct RecognitionTests {
    /// A synthetic "photo" with structure (rectangles and ellipses), so matching has something to lock onto.
    func scene(seed: Int, width: Int = 2000, height: Int = 1500) throws -> Data {
        try TestImage.jpeg(width: width, height: height, colorSpace: .sRGB) { ctx, w, h in
            var rng = SeededRandom(seed: UInt64(seed))
            ctx.setFillColor(red: rng.next(), green: rng.next(), blue: rng.next(), alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            for i in 0..<40 {
                ctx.setFillColor(red: rng.next(), green: rng.next(), blue: rng.next(), alpha: 1)
                let r = CGRect(x: rng.next() * w, y: rng.next() * h, width: (0.05 + rng.next() * 0.3) * w,
                               height: (0.05 + rng.next() * 0.3) * h)
                if i % 2 == 0 { ctx.fill(r) } else { ctx.fillEllipse(in: r) }
            }
        }
    }

    func cg(_ data: Data) throws -> CGImage { try TestImage.decode(data).image }

    /// What the TV holds and serves as a thumbnail: our 3840×2160 render, shrunk to 320×180, recompressed.
    func tvThumbnail(of original: Data, spec: RenderSpec) throws -> CGImage {
        let pipeline = ImagePipeline()
        let render = try pipeline.render(try pipeline.load(original), spec: spec).jpeg
        let full = try cg(render)
        let thumb = try TestImage.jpeg(width: 320, height: 180, colorSpace: .sRGB) { ctx, w, h in
            ctx.interpolationQuality = .high
            ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return try cg(thumb)
    }

    /// The library side: an oriented ~512 px preview, like LibraryStore.thumbnail gives.
    func preview(_ data: Data) throws -> CGImage {
        let full = try cg(data)
        let w = 512, h = Int((512.0 * Double(full.height) / Double(full.width)).rounded())
        return try cg(try TestImage.jpeg(width: w, height: h, colorSpace: .sRGB) { ctx, w, h in
            ctx.interpolationQuality = .high
            ctx.draw(full, in: CGRect(x: 0, y: 0, width: w, height: h))
        })
    }

    @Test(arguments: [
        NormalizedRect(x: 0, y: 0.125, width: 1, height: 0.75),          // full width
        NormalizedRect(x: 0.40, y: 0.30, width: 0.5, height: 0.375),     // half width, off-center
        NormalizedRect(x: 0.05, y: 0.55, width: 0.3, height: 0.225),     // small, near the bottom
    ])
    func recoversTheCrop(_ rect: NormalizedRect) throws {
        let original = try scene(seed: 7)
        let tv = try tvThumbnail(of: original, spec: RenderSpec(mode: .crop(rect)))
        let result = try #require(SubImageMatcher.match(original: try preview(original), tvImage: tv))
        #expect(result.score > SubImageMatcher.threshold)
        guard case .crop(let found) = result.choice else { Issue.record("expected a crop"); return }
        #expect(abs(found.x - rect.x) < 0.02 && abs(found.y - rect.y) < 0.02, "\(found)")
        #expect(abs(found.width - rect.width) < 0.03, "\(found)")
    }

    @Test func unrelatedPhotosDontMatch() throws {
        for seed in 20..<24 {
            let tv = try tvThumbnail(of: try scene(seed: seed), spec: RenderSpec(mode: .crop(NormalizedRect(x: 0, y: 0.125, width: 1, height: 0.75))))
            let other = try preview(try scene(seed: seed + 50))
            #expect(SubImageMatcher.match(original: other, tvImage: tv) == nil, "seed \(seed)")
        }
    }

    func photo(_ name: String, choice: LibraryPhoto.Choice = .undecided, w: Int = 2000, h: Int = 1500) -> LibraryPhoto {
        LibraryPhoto(id: UUID(), displayName: name, source: .copy(filename: "\(name).jpg"), sha256: name,
                     pixelWidth: w, pixelHeight: h, choice: choice, suggestedCenter: nil, tvContentID: nil,
                     uploadedRenderKey: nil, addedAt: Date())
    }

    @Test func matchesOneToOneAndRespectsRejections() throws {
        let a = try scene(seed: 1), b = try scene(seed: 2)
        let rect = NormalizedRect(x: 0, y: 0.1, width: 1, height: 0.75)
        let tvA = try tvThumbnail(of: a, spec: RenderSpec(mode: .crop(rect)))
        let tvB = try tvThumbnail(of: b, spec: RenderSpec(mode: .crop(rect)))
        let pa = photo("a"), pb = photo("b")
        var pbRejected = pb
        pbRejected.notSameAs = ["MY_F0002"]

        let matches = Recognition.match(photos: [pa, pb], originals: [pa.id: try preview(a), pb.id: try preview(b)],
                                        tvImages: ["MY_F0001": tvA, "MY_F0002": tvB])
        #expect(Set(matches.map { "\($0.contentID)=\($0.photoID == pa.id ? "a" : "b")" }) == ["MY_F0001=a", "MY_F0002=b"])

        let withRejection = Recognition.match(photos: [pa, pbRejected],
                                              originals: [pa.id: try preview(a), pbRejected.id: try preview(b)],
                                              tvImages: ["MY_F0001": tvA, "MY_F0002": tvB])
        #expect(withRejection.map(\.contentID) == ["MY_F0001"])
    }

    @Test func applyRecoversCropAndRejectUndoes() {
        let p = photo("x")
        let match = Recognition.Match(photoID: p.id, contentID: "MY_F0004",
                                      choice: .crop(NormalizedRect(x: 0, y: 0.155, width: 1, height: 0.75)), score: 0.99)
        let on = Recognition.apply(match, to: p)
        #expect(on.status == .onTV)
        #expect(on.choice == match.choice)
        #expect(on.recognizedOnTV == true)

        let off = Recognition.reject(on)
        #expect(off.status == .needsCrop)
        #expect(off.tvContentID == nil && off.recognizedOnTV == nil)
        #expect(off.notSameAs == ["MY_F0004"])
    }

    @Test func applyKeepsAChosenCropAndShowsItChanged() {
        let mine = NormalizedRect(x: 0, y: 0, width: 1, height: 0.75)
        let p = photo("x", choice: .crop(mine))
        let match = Recognition.Match(photoID: p.id, contentID: "MY_F0004",
                                      choice: .crop(NormalizedRect(x: 0, y: 0.2, width: 1, height: 0.75)), score: 0.97)
        let on = Recognition.apply(match, to: p)
        #expect(on.choice == .crop(mine))
        #expect(on.status == .changedSinceUpload)
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    /// 0…1
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}
