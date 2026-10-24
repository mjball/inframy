import AppKit
import Foundation
import Photos

/// Keeps the library in step with one Photos album, which becomes the source of truth for what's on the TV:
/// - photos added to the album are imported ("needs crop", or recognized if already on the TV);
/// - photos edited in Photos are re-imported (crop kept if the shape didn't change);
/// - photos removed from the album are reported, so the app can take them off the TV.
/// Inframy only reads from Photos; it never changes the library or the album.
public enum PhotosAlbumSync {
    public enum SyncError: Error, CustomStringConvertible {
        case notAuthorized
        case albumNotFound

        public var description: String {
            switch self {
            case .notAuthorized:
                return "Inframy doesn't have access to Photos. Allow it in System Settings → Privacy & Security → Photos."
            case .albumNotFound: return "The chosen Photos album no longer exists. Pick another one in Settings."
            }
        }
    }

    public struct Album: Sendable, Hashable, Identifiable {
        /// PhotoKit collection id: stable across renames.
        public let id: String
        public let title: String
        public let photoCount: Int
        /// iCloud Shared Albums only keep reduced copies (2048 px long edge): always too small for the TV.
        public let isShared: Bool
    }

    /// An album photo that was too small for the TV. Remembered so it isn't retried (or reported) on every sync,
    /// unless it's edited in Photos.
    public struct SkippedPhoto: Codable, Sendable, Equatable, Identifiable {
        public let assetID: String
        public let name: String
        public let width: Int
        public let height: Int
        public let modified: Date?
        /// When it was taken (or added to Photos): a readable label when the file name is just an id.
        public var created: Date? = nil
        public var id: String { assetID }

        /// The file name, unless it's a meaningless id (files saved into Photos from elsewhere often are).
        public var readableName: String? {
            name.range(of: #"^[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}$"#, options: .regularExpression) == nil ? name : nil
        }
    }

    public struct Asset: Sendable, Equatable {
        public let id: String
        public let modified: Date?

        public init(id: String, modified: Date?) {
            self.id = id
            self.modified = modified
        }
    }

    /// What changed between the album and the library. Pure, so it's testable without Photos.
    public struct Diff: Sendable, Equatable {
        /// Album photos Inframy doesn't have yet.
        public var new: [String] = []
        /// Album photos edited in Photos since they were imported.
        public var edited: [String] = []
        /// Library photos (from this album) that are no longer in it.
        public var removed: [UUID] = []
    }

    public static func diff(album: [Asset], albumID: String, library: [LibraryPhoto]) -> Diff {
        var byAsset: [String: LibraryPhoto] = [:]
        for p in library { if let a = p.photosLocalIdentifier { byAsset[a] = p } }
        let inAlbum = Set(album.map(\.id))
        var d = Diff()
        for asset in album {
            guard let photo = byAsset[asset.id] else { d.new.append(asset.id); continue }
            if let was = photo.photosModifiedAt, let now = asset.modified, now > was.addingTimeInterval(1) {
                d.edited.append(asset.id)
            }
        }
        d.removed = library
            .filter { $0.photosAlbumID == albumID && $0.pendingRemoval != true }
            .filter { $0.photosLocalIdentifier.map { !inAlbum.contains($0) } ?? false }
            .map(\.id)
        return d
    }

    public struct Result: Sendable {
        public var albumTitle = ""
        public var imported: [LibraryPhoto] = []
        /// Existing library photos that changed: re-imported edits, or matched to an album photo by content.
        public var updated: [LibraryPhoto] = []
        public var removed: [UUID] = []
        /// Album photos too small for the TV (carried over from earlier syncs while unchanged).
        public var skipped: [SkippedPhoto] = []
        /// Other problems (export failed, unreadable file).
        public var failures: [String] = []
    }

    // MARK: Photos

    public static var isAuthorized: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .authorized || s == .limited
    }

    public static func authorize() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Every album (including ones in folders and shared albums), with how many photos each has.
    public static func albums() async throws -> [Album] {
        guard await authorize() else { throw SyncError.notAuthorized }
        var result: [Album] = []
        for type in [PHAssetCollectionType.album] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { c, _, _ in
                let count = PHAsset.fetchAssets(in: c, options: imageOptions()).count
                result.append(Album(id: c.localIdentifier, title: c.localizedTitle ?? "Untitled", photoCount: count,
                                    isShared: c.assetCollectionSubtype == .albumCloudShared))
            }
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The id of the album called `title` (to migrate the old by-name setting).
    public static func albumID(named title: String) async -> String? {
        guard await authorize() else { return nil }
        return try? await albums().first { $0.title == title }?.id
    }

    static func imageOptions() -> PHFetchOptions {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return o
    }

    /// Brings the library in line with the album. Doesn't touch the TV; the app acts on `removed`.
    public static func sync(albumID: String, store: LibraryStore, library: [LibraryPhoto],
                            skipped previouslySkipped: [SkippedPhoto] = []) async throws -> Result {
        guard await authorize() else { throw SyncError.notAuthorized }
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject else {
            throw SyncError.albumNotFound
        }
        var assets: [String: PHAsset] = [:]
        var listed: [Asset] = []
        PHAsset.fetchAssets(in: album, options: imageOptions()).enumerateObjects { a, _, _ in
            assets[a.localIdentifier] = a
            listed.append(Asset(id: a.localIdentifier, modified: a.modificationDate))
        }
        var diff = diff(album: listed, albumID: albumID, library: library)
        // Too-small photos aren't retried until they're edited in Photos.
        let modified = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0.modified) })
        let stillSkipped = previouslySkipped
            .filter { s in modified[s.assetID].map { $0 == s.modified } ?? false }
            .map { s -> SkippedPhoto in
                var s = s
                if s.created == nil { s.created = assets[s.assetID]?.creationDate }  // lists saved before dates were kept
                return s
            }
        let skipIDs = Set(stillSkipped.map(\.assetID))
        diff.new.removeAll { skipIDs.contains($0) }

        var result = Result(albumTitle: album.localizedTitle ?? "album", removed: diff.removed, skipped: stillSkipped)
        var known = library
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("InframyAlbum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        for id in diff.new {
            guard let asset = assets[id] else { continue }
            let name = displayName(of: asset)
            do {
                let file = try await exportBestImage(asset, to: temp)
                switch try store.importPhoto(at: file, copy: true, existing: known) {
                case .imported(var photo):
                    photo.displayName = name
                    photo.photosLocalIdentifier = id
                    photo.photosAlbumID = albumID
                    photo.photosModifiedAt = asset.modificationDate
                    if let date = asset.creationDate { photo.addedAt = date }
                    result.imported.append(photo)
                    known.append(photo)
                case .duplicate(let existingID):
                    // Already in the library (e.g. imported by hand): it now belongs to the album.
                    if let i = known.firstIndex(where: { $0.id == existingID }) {
                        known[i].photosLocalIdentifier = id
                        known[i].photosAlbumID = albumID
                        known[i].photosModifiedAt = asset.modificationDate
                        result.updated.append(known[i])
                    }
                }
            } catch LibraryStore.ImportError.tooSmall(_, let w, let h) {
                result.skipped.append(SkippedPhoto(assetID: id, name: name, width: w, height: h, modified: asset.modificationDate,
                                                   created: asset.creationDate))
            } catch {
                result.failures.append(name)
            }
        }

        // Earlier imports were named after Photos' export files ("…-FullSizeRender"): use the real names.
        for i in known.indices {
            guard known[i].photosAlbumID == albumID, let id = known[i].photosLocalIdentifier, let asset = assets[id] else { continue }
            let name = displayName(of: asset)
            if known[i].displayName != name {
                known[i].displayName = name
                if let j = result.updated.firstIndex(where: { $0.id == known[i].id }) { result.updated[j] = known[i] }
                else { result.updated.append(known[i]) }
            }
        }

        for id in diff.edited {
            guard let asset = assets[id], let i = known.firstIndex(where: { $0.photosLocalIdentifier == id }) else { continue }
            do {
                let file = try await exportBestImage(asset, to: temp)
                var photo = try store.replaceOriginal(of: known[i], with: file) ?? known[i]
                photo.photosModifiedAt = asset.modificationDate  // even if the pixels didn't change (e.g. a keyword)
                known[i] = photo
                result.updated.append(photo)
            } catch LibraryStore.ImportError.tooSmall(_, let w, let h) {
                result.skipped.append(SkippedPhoto(assetID: id, name: known[i].displayName, width: w, height: h,
                                                   modified: asset.modificationDate, created: asset.creationDate))
            } catch {
                result.failures.append(known[i].displayName)
            }
        }
        return result
    }

    /// A preview of a Photos asset (read-only), for showing which photo is which.
    public static func thumbnail(assetID: String, maxPixel: CGFloat) async -> CGImage? {
        guard isAuthorized,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // one callback
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: maxPixel, height: maxPixel),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                cont.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    /// The photo's name as Photos shows it (e.g. "IMG_1234"), not the export file's name.
    static func displayName(of asset: PHAsset) -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.first { $0.type == .photo } ?? resources.first
        let name = original?.originalFilename ?? asset.localIdentifier
        return (name as NSString).deletingPathExtension
    }

    /// The edited version if it's big enough for the TV, else the untouched original if that is.
    static func exportBestImage(_ asset: PHAsset, to dir: URL) async throws -> URL {
        let edited = try await exportImage(asset, to: dir)
        if let size = LibraryStore.orientedPixelSize(of: edited), LibraryStore.isLargeEnough(size) { return edited }
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.contains(where: { $0.type == .fullSizePhoto }),
              let original = resources.first(where: { $0.type == .photo }) else { return edited }
        let url = dir.appendingPathComponent(UUID().uuidString + "-" + original.originalFilename)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: original, toFile: url, options: options)
        if let size = LibraryStore.orientedPixelSize(of: url), LibraryStore.isLargeEnough(size) { return url }
        return edited
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

    /// Calls `onChange` whenever the Photos library changes (added, removed or edited photos), while it's alive.
    public final class Watcher: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
        private let onChange: @Sendable () -> Void

        public init(onChange: @escaping @Sendable () -> Void) {
            self.onChange = onChange
            super.init()
            PHPhotoLibrary.shared().register(self)
        }

        deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

        public func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
    }
}
