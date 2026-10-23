import Foundation
import Testing
@testable import InframyKit

struct RotationTests {
    func photo(_ name: String, onTV: Bool, since: Double = 0, absentSince: Double? = nil, added: Double = 0,
               choice: LibraryPhoto.Choice = .crop(.full), pinned: Bool = false) -> LibraryPhoto {
        var p = LibraryPhoto(id: UUID(), displayName: name, source: .copy(filename: "\(name).jpg"), sha256: name,
                             pixelWidth: 1920, pixelHeight: 1080, choice: choice, suggestedCenter: nil,
                             tvContentID: onTV ? "MY_\(name)" : nil, uploadedRenderKey: nil,
                             addedAt: Date(timeIntervalSince1970: added))
        if onTV { p.onTVSince = Date(timeIntervalSince1970: since); p.uploadedRenderKey = p.renderKey }
        p.lastOnTV = absentSince.map { Date(timeIntervalSince1970: $0) }
        p.pinned = pinned ? true : nil
        return p
    }

    func names(_ ids: [UUID], _ photos: [LibraryPhoto]) -> [String] {
        ids.compactMap { id in photos.first { $0.id == id }?.displayName }
    }

    @Test func fillsFreeSlotsLongestAbsentFirst() {
        let photos = [photo("a", onTV: false, absentSince: 300), photo("b", onTV: false, added: 100),
                      photo("c", onTV: false, absentSince: 50)]
        let plan = RotationPlanner.plan(photos: photos, poolSize: 2, swapFraction: 0)
        #expect(names(plan.upload, photos) == ["c", "b"])
        #expect(plan.remove.isEmpty)
    }

    @Test func swapsOldestOnTVForLongestAbsent() {
        let photos = [photo("t1", onTV: true, since: 10), photo("t2", onTV: true, since: 20),
                      photo("t3", onTV: true, since: 30), photo("t4", onTV: true, since: 40),
                      photo("o1", onTV: false, absentSince: 5), photo("o2", onTV: false, absentSince: 1)]
        let plan = RotationPlanner.plan(photos: photos, poolSize: 4, swapFraction: 0.5)
        #expect(names(plan.upload, photos) == ["o2", "o1"])
        #expect(names(plan.remove, photos) == ["t1", "t2"])
    }

    @Test func neverSendsUndecidedOrSkippedAndKeepsPinned() {
        let photos = [photo("pinnedOld", onTV: true, since: 1, pinned: true), photo("t", onTV: true, since: 2),
                      photo("undecided", onTV: false, choice: .undecided), photo("skipped", onTV: false, choice: .skip),
                      photo("ok", onTV: false)]
        let plan = RotationPlanner.plan(photos: photos, poolSize: 2, swapFraction: 1)
        #expect(names(plan.upload, photos) == ["ok"])
        #expect(names(plan.remove, photos) == ["t"])
    }

    @Test func shrinksWhenOverThePool() {
        let photos = [photo("t1", onTV: true, since: 1), photo("t2", onTV: true, since: 2), photo("t3", onTV: true, since: 3)]
        let plan = RotationPlanner.plan(photos: photos, poolSize: 1, swapFraction: 0.2)
        #expect(plan.upload.isEmpty)
        #expect(names(plan.remove, photos) == ["t1", "t2"])
    }

    @Test func nothingToDoWhenEverythingFits() {
        let photos = [photo("t1", onTV: true), photo("t2", onTV: true)]
        #expect(RotationPlanner.plan(photos: photos, poolSize: 5, swapFraction: 0.2).isEmpty)
    }
}

@Suite(.serialized)
struct RotatorTests {
    @Test func failedUploadRemovesNothingAndFlagsFull() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("n.jpg")
        try TestImage.jpeg(width: 1920, height: 1080, colorSpace: .sRGB) { ctx, w, h in
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }.write(to: src)
        let store = LibraryStore(directory: dir.appendingPathComponent("data"))
        guard case .imported(let incoming) = try store.importPhoto(at: src, copy: false, existing: []) else { return }
        var old = incoming
        old.id = UUID()
        old.tvContentID = "MY_F0001"
        old.onTVSince = Date(timeIntervalSince1970: 0)

        let tv = try await FakeTV { req, _ in [Frame.error(id: req.id, request: req.name, code: "-1")] }
        defer { tv.stop() }
        let rotator = Rotator(sender: PhotoSender(store: store, cache: RenderCache(directory: dir.appendingPathComponent("r"))))
        let plan = RotationPlanner.Plan(upload: [incoming.id], remove: [old.id])
        let outcome = await rotator.run(plan, photos: [incoming, old], client: tv.client())
        #expect(outcome.probablyFull)
        #expect(outcome.updated.isEmpty)
        #expect(!tv.requests.contains { $0.name == "delete_image_list" })
    }
}
