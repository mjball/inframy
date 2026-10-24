import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import InframyKit

struct CropGeometryTests {
    let size = CGSize(width: 4000, height: 3000)  // 4:3

    @Test func zoomOneIsTheLargestPanelArea() {
        let g = CropGeometry(imageSize: size)
        #expect(g.rect.width == 1)
        #expect(abs(g.rect.height - 0.75) < 1e-9)
        #expect(abs(g.rect.y - 0.125) < 1e-9)
    }

    @Test func rectStaysInsideTheImage() {
        var g = CropGeometry(imageSize: size, center: CGPoint(x: 0.9, y: 0.01))
        #expect(g.rect.y >= 0 && g.rect.x >= 0 && g.rect.x + g.rect.width <= 1.0000001)
        g.setZoom(2)
        g.nudge(dx: 5, dy: 5)
        #expect(g.rect.x + g.rect.width <= 1.0000001 && g.rect.y + g.rect.height <= 1.0000001)
    }

    @Test func zoomIsClampedAndKeepsAnchor() {
        var g = CropGeometry(imageSize: size)
        g.setZoom(0.5)
        #expect(g.zoom == 1)
        g.setZoom(1000)
        #expect(g.zoom == g.maxZoom)
        #expect(abs(g.rect.width * size.width - CropGeometry.minimumCropWidth) < 0.001)

        var h = CropGeometry(imageSize: size)
        let before = h.rect
        let anchor = CGPoint(x: 0.25, y: 0.5)
        let imagePoint = CGPoint(x: before.x + anchor.x * before.width, y: before.y + anchor.y * before.height)
        h.zoom(by: 2, anchor: anchor)
        let after = h.rect
        #expect(abs(after.x + anchor.x * after.width - imagePoint.x) < 1e-9)
        #expect(abs(after.y + anchor.y * after.height - imagePoint.y) < 1e-9)
    }

    @Test func draggingTheImageRightShowsMoreOfItsLeft() {
        // Big enough that 2× zoom stays above panel resolution.
        var g = CropGeometry(imageSize: CGSize(width: 12000, height: 9000))
        g.setZoom(2)
        let x0 = g.rect.x
        g.pan(by: CGSize(width: 100, height: 0), frameSize: CGSize(width: 1600, height: 900))
        #expect(g.rect.x < x0)
        #expect(abs((x0 - g.rect.x) - 100.0 / 1600 * g.rect.width) < 1e-9)
    }

    @Test func roundTripsThroughARect() {
        var g = CropGeometry(imageSize: size, center: CGPoint(x: 0.4, y: 0.6))
        g.setZoom(1.7)
        let again = CropGeometry(imageSize: size, rect: g.rect)
        #expect(abs(again.zoom - g.zoom) < 1e-9)
        #expect(abs(again.center.x - g.center.x) < 1e-9 && abs(again.center.y - g.center.y) < 1e-9)
    }

    @Test func upscaleReflectsCropWidth() {
        let small = CropGeometry(imageSize: CGSize(width: 1920, height: 1080))
        #expect(abs(small.upscale - 2) < 1e-9)
    }
}

struct LibraryStoreTests {
    func tempStore() throws -> (LibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inframy-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (LibraryStore(directory: dir.appendingPathComponent("data")), dir)
    }

    func writeJPEG(_ url: URL, width: Int, height: Int, orientation: Int = 1, gray: CGFloat = 0.5) throws {
        try TestImage.jpeg(width: width, height: height, colorSpace: .sRGB,
                           properties: [kCGImagePropertyOrientation: orientation]) { ctx, w, h in
            ctx.setFillColor(gray: gray, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }.write(to: url)
    }

    @Test func importsByReferenceAndDedupes() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("lake.jpg")
        try writeJPEG(file, width: 4000, height: 3000)

        guard case .imported(let photo) = try store.importPhoto(at: file, copy: false, existing: [], minimumSize: .zero) else {
            Issue.record("expected import"); return
        }
        #expect(photo.displayName == "lake")
        #expect(photo.status == .needsCrop)  // 4:3: Matt has to choose
        #expect(store.url(for: photo) == file)
        #expect(!FileManager.default.fileExists(atPath: store.originalsDirectory.path))  // not copied

        let again = try store.importPhoto(at: file, copy: false, existing: [photo], minimumSize: .zero)
        guard case .duplicate(let id) = again else { Issue.record("expected duplicate"); return }
        #expect(id == photo.id)
    }

    @Test func panelShapedPhotosNeedNoCrop() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("wide.jpg")
        try writeJPEG(file, width: 1920, height: 1080)
        guard case .imported(let photo) = try store.importPhoto(at: file, copy: false, existing: [], minimumSize: .zero) else {
            Issue.record("expected import"); return
        }
        #expect(photo.choice == .crop(.full))
        #expect(photo.status == .readyToSend)
    }

    @Test func copiesTemporaryFilesAndReportsOrientedSize() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("from-photos.jpg")
        try writeJPEG(file, width: 4000, height: 3000, orientation: 6)  // displays as portrait
        guard case .imported(let photo) = try store.importPhoto(at: file, copy: true, existing: [], minimumSize: .zero) else {
            Issue.record("expected import"); return
        }
        #expect(photo.pixelWidth == 3000 && photo.pixelHeight == 4000)
        try FileManager.default.removeItem(at: file)  // the temp file goes away; our copy stays
        let url = try #require(store.url(for: photo))
        #expect(url.path.hasPrefix(store.originalsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func saveAndLoadRoundTrip() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jpg")
        try writeJPEG(file, width: 4000, height: 3000)
        guard case .imported(var photo) = try store.importPhoto(at: file, copy: false, existing: [], minimumSize: .zero) else { return }
        photo.choice = .crop(NormalizedRect(x: 0, y: 0.1, width: 1, height: 0.75))
        photo.suggestedCenter = [0.5, 0.48]
        photo.addedAt = Date(timeIntervalSince1970: 1_792_700_000)  // ISO 8601 keeps whole seconds
        try store.save([photo])
        #expect(store.load() == [photo])
    }

    @Test func statusTracksCropChangesAfterUpload() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jpg")
        try writeJPEG(file, width: 4000, height: 3000)
        guard case .imported(var photo) = try store.importPhoto(at: file, copy: false, existing: [], minimumSize: .zero) else { return }
        photo.choice = .crop(NormalizedRect(x: 0, y: 0.1, width: 1, height: 0.75))
        photo.tvContentID = "MY_F0009"
        photo.uploadedRenderKey = photo.renderKey
        #expect(photo.status == .onTV)
        photo.choice = .crop(NormalizedRect(x: 0, y: 0.2, width: 1, height: 0.75))
        #expect(photo.status == .changedSinceUpload)
        photo.choice = .skip
        #expect(photo.status == .skipped && photo.renderSpec == nil)
    }
}

/// The send flow end to end against the fake TV: render, upload over d2d, replace the old TV copy.
@Suite(.serialized)
struct PhotoSenderTests {
    @Test func sendsAndReplacesOldVersion() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inframy-send-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("p.jpg")
        try TestImage.jpeg(width: 2000, height: 1500, colorSpace: .sRGB) { ctx, w, h in
            ctx.setFillColor(red: 0.3, green: 0.4, blue: 0.9, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }.write(to: file)
        let store = LibraryStore(directory: dir.appendingPathComponent("data"))
        guard case .imported(var photo) = try store.importPhoto(at: file, copy: false, existing: [], minimumSize: .zero) else { return }
        photo.choice = .crop(NormalizedRect(x: 0, y: 0.125, width: 1, height: 0.75))
        photo.tvContentID = "MY_F0001"  // an older version is on the TV

        let tvBox = Box<FakeTV>()
        let idBox = Box<String>()
        let d2d = try await FakeD2D(mode: .receive) { _ in
            tvBox.value?.broadcast(Frame.d2d(["id": .string(idBox.value!), "event": "image_added", "content_id": "MY_F0002"]))
        }
        defer { d2d.stop() }
        let tv = try await FakeTV { req, _ in
            switch req.name {
            case "send_image":
                idBox.value = req.id
                return [Frame.readyToUse(id: req.id, port: d2d.port)]
            case "delete_image_list":
                return [Frame.d2d(["id": .string(req.id), "event": "image_list_deleted",
                                   "content_id_list": .string(#"[{"content_id":"MY_F0001"}]"#)])]
            default: return []
            }
        }
        tvBox.value = tv
        defer { tv.stop() }

        let sender = PhotoSender(store: store, cache: RenderCache(directory: dir.appendingPathComponent("renders")))
        let stages = Box<[PhotoSender.Stage]>()
        stages.value = []
        let updated = try await sender.send(photo, via: tv.client()) { stage in stages.value = (stages.value ?? []) + [stage] }

        #expect(updated.tvContentID == "MY_F0002")
        #expect(updated.status == .onTV)
        #expect(tv.requests.map(\.name) == ["send_image", "delete_image_list"])
        #expect(tv.requests.last?.params["content_id_list"]?.arrayValue?.first?["content_id"] == "MY_F0001")
        #expect(stages.value == [.rendering, .uploading, .replacing, .done(contentID: "MY_F0002")])

        // The bytes the TV got are a 3840×2160 JPEG.
        let received = d2d.received
        let headerLength = Int(received.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let jpeg = received.suffix(from: 4 + headerLength)
        let decoded = try TestImage.decode(Data(jpeg))
        #expect(decoded.image.width == 3840 && decoded.image.height == 2160)
    }

    @Test func refusesUndecidedPhotos() async throws {
        let photo = LibraryPhoto(id: UUID(), displayName: "x", source: .copy(filename: "x.jpg"), sha256: "s",
                                 pixelWidth: 4000, pixelHeight: 3000, choice: .undecided, suggestedCenter: nil,
                                 tvContentID: nil, uploadedRenderKey: nil, addedAt: Date())
        let tv = try await FakeTV { _, _ in [] }
        defer { tv.stop() }
        await #expect(throws: PhotoSender.SendError.self) { _ = try await PhotoSender().send(photo, via: tv.client()) }
        #expect(tv.requests.isEmpty)
    }
}

struct AlbumSyncTests {
    @Test func onlyUnknownAlbumPhotosAreNew() {
        var known = LibraryPhoto(id: UUID(), displayName: "a", source: .copy(filename: "a.jpg"), sha256: "1",
                                 pixelWidth: 10, pixelHeight: 10, choice: .undecided, suggestedCenter: nil,
                                 tvContentID: nil, uploadedRenderKey: nil, addedAt: Date())
        known.photosLocalIdentifier = "A/L0/001"
        #expect(PhotosAlbumSync.newIdentifiers(album: ["A/L0/001", "B/L0/001"], library: [known]) == ["B/L0/001"])
    }

    @Test func libraryDecodesWithoutNewFields() throws {
        // A library.json written before photosLocalIdentifier/sharpen existed still loads.
        let json = #"""
        [{"id":"8C1B4E0A-8D64-4C34-9C5B-2D7C0E8F6A11","displayName":"x","source":{"copy":{"filename":"x.jpg"}},
          "sha256":"s","pixelWidth":10,"pixelHeight":10,"choice":{"undecided":{}},"addedAt":"2026-10-23T10:00:00Z"}]
        """#
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(json.utf8).write(to: dir.appendingPathComponent("library.json"))
        let photos = LibraryStore(directory: dir).load()
        #expect(photos.count == 1)
        #expect(photos.first?.photosLocalIdentifier == nil && photos.first?.sharpen == nil)
    }

    @Test func sharpenChangesTheRenderKey() {
        var p = LibraryPhoto(id: UUID(), displayName: "a", source: .copy(filename: "a.jpg"), sha256: "1",
                             pixelWidth: 1920, pixelHeight: 1080, choice: .crop(.full), suggestedCenter: nil,
                             tvContentID: nil, uploadedRenderKey: nil, addedAt: Date())
        let plain = p.renderKey
        p.sharpen = true
        #expect(p.renderKey != plain)
        #expect(p.renderSpec?.sharpen == true)
    }
}

struct MinimumSizeTests {
    @Test func refusesPhotosSmallerThanThePanel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("min-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(directory: dir.appendingPathComponent("data"))
        let phonePortrait = dir.appendingPathComponent("portrait.jpg")
        try TestImage.jpeg(width: 3024, height: 4032, colorSpace: .sRGB) { ctx, w, h in
            ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }.write(to: phonePortrait)
        #expect(throws: LibraryStore.ImportError.self) { _ = try store.importPhoto(at: phonePortrait, copy: false, existing: []) }

        let big = dir.appendingPathComponent("big.jpg")
        try TestImage.jpeg(width: 3840, height: 2160, colorSpace: .sRGB) { ctx, w, h in
            ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }.write(to: big)
        guard case .imported(let photo) = try store.importPhoto(at: big, copy: false, existing: []) else {
            Issue.record("3840×2160 should import"); return
        }
        #expect(photo.status == .readyToSend)
        #expect(LibraryStore.isLargeEnough(CGSize(width: 5712, height: 4284)))
        #expect(!LibraryStore.isLargeEnough(CGSize(width: 3839, height: 2160)))
    }

    @Test func legacyFitWithBlurLoadsAsUndecided() throws {
        let json = #"""
        [{"id":"8C1B4E0A-8D64-4C34-9C5B-2D7C0E8F6A11","displayName":"old","source":{"copy":{"filename":"x.jpg"}},
          "sha256":"s","pixelWidth":5000,"pixelHeight":4000,"choice":{"fitWithBlur":{}},"addedAt":"2026-10-23T10:00:00Z"},
         {"id":"8C1B4E0A-8D64-4C34-9C5B-2D7C0E8F6A12","displayName":"crop","source":{"copy":{"filename":"y.jpg"}},
          "sha256":"t","pixelWidth":5000,"pixelHeight":4000,
          "choice":{"crop":{"_0":{"x":0,"y":0.1,"width":1,"height":0.75}}},"addedAt":"2026-10-23T10:00:00Z"}]
        """#
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(json.utf8).write(to: dir.appendingPathComponent("library.json"))
        let store = LibraryStore(directory: dir)
        let photos = store.load()
        #expect(photos.map(\.choice) == [.undecided, .crop(NormalizedRect(x: 0, y: 0.1, width: 1, height: 0.75))])
        try store.save(photos)
        #expect(store.load() == photos)
    }

    @Test func cropCantZoomPastPanelResolution() {
        var g = CropGeometry(imageSize: CGSize(width: 5712, height: 4284))
        g.setZoom(100)
        #expect(abs(g.rect.width * 5712 - 3840) < 0.5)
        #expect(g.upscale <= 1.0001)
        let exact = CropGeometry(imageSize: CGSize(width: 3840, height: 2160))
        #expect(exact.maxZoom == 1)
    }
}
