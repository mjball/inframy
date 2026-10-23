import Foundation
import Photos

/// Keeps the library in step with a Photos album (default "Frame", SPEC Phase 3). New photos in the album are
/// imported as "needs crop": nothing is cropped or sent automatically. Photos removed from the album stay in the
/// library (and on the TV) until Matt removes them.
public enum PhotosAlbumSync {
    public static let defaultAlbumName = "Frame"

    public enum SyncError: Error, CustomStringConvertible {
        case notAuthorized
        case albumNotFound(String)

        public var description: String {
            switch self {
            case .notAuthorized:
                return "Inframy doesn't have access to Photos. Allow it in System Settings → Privacy & Security → Photos."
            case .albumNotFound(let name): return "There's no album named \"\(name)\" in Photos."
            }
        }
    }

    public struct Result: Sendable {
        public var imported: [LibraryPhoto] = []
        /// Library photos that matched by content and just got their Photos id recorded.
        public var linked: [LibraryPhoto] = []
        public var failures: [String] = []
    }

    public static func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Album assets not yet in the library, by Photos id.
    public static func newIdentifiers(album: [String], library: [LibraryPhoto]) -> [String] {
        let known = Set(library.compactMap(\.photosLocalIdentifier))
        return album.filter { !known.contains($0) }
    }

    /// Imports new photos from `albumName`. Originals are exported (edited version if edited in Photos) and copied
    /// into the library's Originals folder.
    public static func sync(albumName: String, store: LibraryStore, library: [LibraryPhoto]) async throws -> Result {
        guard await authorize() else { throw SyncError.notAuthorized }
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        var album: PHAssetCollection?
        collections.enumerateObjects { c, _, stop in
            if c.localizedTitle == albumName { album = c; stop.pointee = true }
        }
        guard let album else { throw SyncError.albumNotFound(albumName) }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetch = PHAsset.fetchAssets(in: album, options: options)
        var assets: [String: PHAsset] = [:]
        var order: [String] = []
        fetch.enumerateObjects { a, _, _ in assets[a.localIdentifier] = a; order.append(a.localIdentifier) }

        var result = Result()
        var known = library
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("InframyAlbum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        for id in newIdentifiers(album: order, library: library) {
            guard let asset = assets[id] else { continue }
            do {
                let file = try await exportImage(asset, to: temp)
                switch try store.importPhoto(at: file, copy: true, existing: known) {
                case .imported(var photo):
                    photo.photosLocalIdentifier = id
                    if let date = asset.creationDate { photo.addedAt = date }
                    result.imported.append(photo)
                    known.append(photo)
                case .duplicate(let existingID):
                    if var existing = known.first(where: { $0.id == existingID }), existing.photosLocalIdentifier == nil {
                        existing.photosLocalIdentifier = id
                        result.linked.append(existing)
                    }
                }
            } catch {
                result.failures.append(asset.value(forKey: "filename") as? String ?? id)
            }
        }
        return result
    }

    /// Writes the asset's current image (the edited version if there is one) to `dir`.
    static func exportImage(_ asset: PHAsset, to dir: URL) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }) else {
            throw ImagePipelineError.unreadable("no image resource")
        }
        let url = dir.appendingPathComponent(UUID().uuidString + "-" + resource.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // iCloud Photos originals
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }
}
