import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import InframyKit

struct AdoptionTests {
    /// A synthetic "photo" with structure (gradient + shapes), so hashes are meaningful.
    func scene(seed: Int, width: Int = 1600, height: Int = 900) throws -> Data {
        try TestImage.jpeg(width: width, height: height, colorSpace: .sRGB) { ctx, w, h in
            var rng = SeededRandom(seed: UInt64(seed))
            for i in 0..<12 {
                ctx.setFillColor(red: rng.next(), green: rng.next(), blue: rng.next(), alpha: 1)
                let r = CGRect(x: rng.next() * w, y: rng.next() * h, width: (0.2 + rng.next() * 0.5) * w,
                               height: (0.2 + rng.next() * 0.5) * h)
                if i % 2 == 0 { ctx.fill(r) } else { ctx.fillEllipse(in: r) }
            }
        }
    }

    func cg(_ data: Data) throws -> CGImage { try TestImage.decode(data).image }

    @Test func sameImageAfterResizeAndRecompressionIsClose() throws {
        let original = try scene(seed: 1)
        let pipeline = ImagePipeline()
        // What the TV holds (a 3840×2160 render), then its 320×180 thumbnail, recompressed.
        let render = try pipeline.render(try pipeline.load(original), spec: RenderSpec(mode: .crop(.full))).jpeg
        let thumbCG = try #require(LibraryStore.thumbnail(of: try write(render), maxPixel: 320))
        let thumb = try TestImage.jpeg(width: thumbCG.width, height: thumbCG.height, colorSpace: .sRGB) { ctx, w, h in
            ctx.draw(thumbCG, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let d = PerceptualHash.distance(PerceptualHash.dHash(try cg(original)), PerceptualHash.dHash(try cg(thumb)))
        #expect(d <= 6, "distance \(d)")
    }

    @Test func differentImagesAreFar() throws {
        var distances: [Int] = []
        for seed in 2...6 {
            let a = PerceptualHash.dHash(try cg(try scene(seed: seed)))
            let b = PerceptualHash.dHash(try cg(try scene(seed: seed + 100)))
            distances.append(PerceptualHash.distance(a, b))
        }
        #expect(distances.allSatisfy { $0 > Adoption.defaultThreshold }, "\(distances)")
    }

    @Test func proposalsAreOneToOneAndClosestFirst() {
        let p1 = UUID(), p2 = UUID()
        let tv: [String: UInt64] = ["MY_F0001": 0b1111, "MY_F0002": 0xFFFF_0000_0000_0000, "MY_F0003": 0b1110]
        let photos: [UUID: UInt64] = [p1: 0b1111, p2: 0xFFFF_0000_0000_0001]
        let proposals = Adoption.propose(tvHashes: tv, photoHashes: photos)
        // MY_F0001 is an exact match for p1; MY_F0003 is also close to p1 but p1 is taken.
        #expect(proposals == [
            Adoption.Proposal(contentID: "MY_F0001", photoID: p1, distance: 0),
            Adoption.Proposal(contentID: "MY_F0002", photoID: p2, distance: 1),
        ])
    }

    @Test func linkMarksPhotoOnTV() {
        let photo = LibraryPhoto(id: UUID(), displayName: "x", source: .copy(filename: "x.jpg"), sha256: "s",
                                 pixelWidth: 1920, pixelHeight: 1080, choice: .crop(.full), suggestedCenter: nil,
                                 tvContentID: nil, uploadedRenderKey: nil, addedAt: Date())
        let linked = Adoption.link(photo, to: "MY_F0007")
        #expect(linked.tvContentID == "MY_F0007")
        #expect(linked.status == .onTV)
    }

    @Test func panelHashMatchesTheRenderOfTheCrop() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("p.jpg")
        try scene(seed: 9, width: 2000, height: 1500).write(to: src)
        let store = LibraryStore(directory: dir.appendingPathComponent("data"))
        guard case .imported(var photo) = try store.importPhoto(at: src, copy: false, existing: []) else { return }
        photo.choice = .crop(NormalizedRect(x: 0, y: 0.2, width: 1, height: 0.75))
        let hash = try #require(PerceptualHash.panelHash(of: photo, store: store))
        let render = try ImagePipeline().render(src, spec: photo.renderSpec!).jpeg
        let d = PerceptualHash.distance(hash, PerceptualHash.dHash(try cg(render)))
        #expect(d <= 6, "distance \(d)")
    }

    func write(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url)
        return url
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
