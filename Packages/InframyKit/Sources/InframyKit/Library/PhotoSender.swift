import Foundation

/// Renders a library photo and puts it on the TV with no mat.
public struct PhotoSender: Sendable {
    public let store: LibraryStore
    public let cache: RenderCache

    public init(store: LibraryStore = LibraryStore(), cache: RenderCache = RenderCache()) {
        self.store = store
        self.cache = cache
    }

    public enum Stage: Sendable, Equatable {
        case rendering, uploading, replacing, done(contentID: String)
    }

    public enum SendError: Error, CustomStringConvertible {
        case notDecided
        case missingOriginal(String)

        public var description: String {
            switch self {
            case .notDecided: return "Choose a crop (or Fit) before sending."
            case .missingOriginal(let name): return "Can't find the original of \(name). Was it moved or deleted?"
            }
        }
    }

    /// Renders (cached), uploads, and returns the updated photo. If the photo was already on the TV with a different
    /// crop, the old TV copy is deleted after the new one is in. Only ever deletes items this library uploaded.
    public func send(_ photo: LibraryPhoto, via client: ArtClient,
                     progress: @Sendable (Stage) -> Void = { _ in }) async throws -> LibraryPhoto {
        guard let spec = photo.renderSpec, let key = photo.renderKey else { throw SendError.notDecided }
        guard let source = store.url(for: photo) else { throw SendError.missingOriginal(photo.displayName) }
        progress(.rendering)
        let cache = self.cache
        let rendered = try await Task.detached(priority: .userInitiated) {
            try cache.render(source, spec: spec).url
        }.value
        progress(.uploading)
        let contentID = try await client.upload(jpeg: try Data(contentsOf: rendered), matte: "none")

        var updated = photo
        if let old = photo.tvContentID, old != contentID {
            progress(.replacing)
            _ = try? await client.delete([old])
        }
        updated.tvContentID = contentID
        updated.uploadedRenderKey = key
        updated.onTVSince = Date()
        progress(.done(contentID: contentID))
        return updated
    }
}
