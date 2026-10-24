import CoreGraphics
import Foundation
import ImageIO

/// A photo Matt has imported. Originals are never modified: Finder files are referenced by bookmark, and photos
/// dragged from Photos (which only hands out copies) are copied into the library's `Originals` folder.
public struct LibraryPhoto: Codable, Identifiable, Sendable, Equatable, Hashable {
    /// Matt's decision for this photo. Nothing is sent until it's `.crop`: Inframy never crops on its own.
    public enum Choice: Codable, Sendable, Equatable, Hashable {
        case undecided
        case crop(NormalizedRect)
        case skip

        // Same JSON shape Swift synthesizes ({"crop":{"_0":{…}}}), but a removed mode such as the old
        // "fitWithBlur" decodes as .undecided instead of failing the whole library.
        private enum CodingKeys: String, CodingKey { case undecided, crop, skip }
        private enum CropKeys: String, CodingKey { case _0 }
        private struct Empty: Codable {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if c.contains(.crop) {
                self = .crop(try c.nestedContainer(keyedBy: CropKeys.self, forKey: .crop).decode(NormalizedRect.self, forKey: ._0))
            } else if c.contains(.skip) {
                self = .skip
            } else {
                self = .undecided
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .undecided: try c.encode(Empty(), forKey: .undecided)
            case .skip: try c.encode(Empty(), forKey: .skip)
            case .crop(let rect):
                var n = c.nestedContainer(keyedBy: CropKeys.self, forKey: .crop)
                try n.encode(rect, forKey: ._0)
            }
        }
    }

    public enum Source: Codable, Sendable, Equatable, Hashable {
        /// A file elsewhere on disk. `bookmark` follows it if it moves.
        case file(path: String, bookmark: Data?)
        /// A copy inside the library's Originals folder.
        case copy(filename: String)
    }

    public var id: UUID
    public var displayName: String
    public var source: Source
    public var sha256: String
    /// Size as displayed (EXIF orientation applied).
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var choice: Choice
    /// Where the crop editor's frame starts (computer-vision hint), normalized, top-left origin.
    public var suggestedCenter: [Double]?
    /// The TV item this photo was uploaded as.
    public var tvContentID: String?
    /// Cache key of the render that was uploaded; if the crop changes, the TV copy is stale.
    public var uploadedRenderKey: String?
    public var addedAt: Date
    /// PhotoKit `localIdentifier` when the photo came from the synced Photos album.
    public var photosLocalIdentifier: String? = nil
    /// Light unsharp mask after resizing (SPEC §5: off by default, judged on the actual TV).
    public var sharpen: Bool? = nil
    /// When the current TV copy went up (rotation takes the oldest down first).
    public var onTVSince: Date? = nil
    /// When it last left the TV (rotation brings back the longest-absent first).
    public var lastOnTV: Date? = nil
    /// Never rotated off the TV.
    public var pinned: Bool? = nil
    /// True when Inframy recognized this photo on the TV (rather than sending it). Its crop was recovered from the
    /// TV copy. "Not the same photo" undoes this.
    public var recognizedOnTV: Bool? = nil
    /// TV items Matt said aren't this photo; never matched again.
    public var notSameAs: [String]? = nil

    public var imageSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }
    public var aspect: Double { Double(pixelWidth) / Double(max(pixelHeight, 1)) }
    /// Already 16:9: no crop to choose, only resizing.
    public var isPanelShaped: Bool { abs(aspect - Panel.aspect) / Panel.aspect < 0.005 }

    public var renderSpec: RenderSpec? {
        switch choice {
        case .crop(let rect): return RenderSpec(mode: .crop(rect), sharpen: sharpen ?? false)
        case .undecided, .skip: return nil
        }
    }

    public var renderKey: String? {
        renderSpec.map { ImagePipeline.cacheKey(sourceSHA256: sha256, spec: $0) }
    }

    public enum Status: Sendable, Equatable {
        case needsCrop, skipped, readyToSend, onTV, changedSinceUpload
    }

    public var status: Status {
        switch choice {
        case .undecided: return .needsCrop
        case .skip: return .skipped
        case .crop:
            guard tvContentID != nil else { return .readyToSend }
            return uploadedRenderKey == renderKey ? .onTV : .changedSinceUpload
        }
    }
}

/// Reads and writes the library (JSON) and imports photos into it.
/// Default location: ~/Library/Application Support/Inframy/.
public struct LibraryStore: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Inframy")) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent("library.json") }
    public var originalsDirectory: URL { directory.appendingPathComponent("Originals") }

    public func load() -> [LibraryPhoto] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LibraryPhoto].self, from: data)) ?? []
    }

    public func save(_ photos: [LibraryPhoto]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(photos).write(to: fileURL, options: .atomic)
    }

    /// The original's current location (following a bookmark if the file moved).
    public func url(for photo: LibraryPhoto) -> URL? {
        switch photo.source {
        case .copy(let filename):
            return originalsDirectory.appendingPathComponent(filename)
        case .file(let path, let bookmark):
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            if let bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale) {
                    return url
                }
            }
            return nil
        }
    }

    public enum ImportResult: Sendable {
        case imported(LibraryPhoto)
        case duplicate(of: UUID)
    }

    public enum ImportError: Error, CustomStringConvertible {
        /// Smaller than the panel: it would have to be upscaled, and the TV is for showing off great photos.
        case tooSmall(name: String, width: Int, height: Int)

        public var description: String {
            switch self {
            case .tooSmall(let name, let w, let h):
                return "\(name) is \(w)×\(h). The TV needs at least \(Panel.width)×\(Panel.height) so photos aren't upscaled."
            }
        }
    }

    /// Whether a photo of `size` (oriented) is big enough for a full-resolution 16:9 crop.
    public static func isLargeEnough(_ size: CGSize, minimum: CGSize = Panel.minimumSourceSize) -> Bool {
        size.width >= minimum.width && size.height >= minimum.height
    }

    /// Adds a file by reference (Finder). `copy: true` copies it into Originals instead (Photos drags, picker
    /// temp files). Skips photos already in the library (same SHA-256).
    /// Refuses photos smaller than `minimumSize` (default: the panel, 3840×2160).
    public func importPhoto(at url: URL, copy: Bool, existing: [LibraryPhoto],
                            minimumSize: CGSize = Panel.minimumSourceSize) throws -> ImportResult {
        let sha = try ImagePipeline.sha256(of: url)
        if let dup = existing.first(where: { $0.sha256 == sha }) { return .duplicate(of: dup.id) }
        guard let size = Self.orientedPixelSize(of: url) else { throw ImagePipelineError.unreadable(url.lastPathComponent) }
        guard Self.isLargeEnough(size, minimum: minimumSize) else {
            throw ImportError.tooSmall(name: url.lastPathComponent, width: Int(size.width), height: Int(size.height))
        }

        let id = UUID()
        let source: LibraryPhoto.Source
        if copy {
            try FileManager.default.createDirectory(at: originalsDirectory, withIntermediateDirectories: true)
            let filename = "\(id.uuidString).\(url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased())"
            try FileManager.default.copyItem(at: url, to: originalsDirectory.appendingPathComponent(filename))
            source = .copy(filename: filename)
        } else {
            source = .file(path: url.path, bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        }
        var photo = LibraryPhoto(id: id, displayName: url.deletingPathExtension().lastPathComponent, source: source,
                                 sha256: sha, pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                                 choice: .undecided, suggestedCenter: nil, tvContentID: nil, uploadedRenderKey: nil,
                                 addedAt: Date())
        // A photo that's already 16:9 has nothing to choose: resize only.
        if photo.isPanelShaped { photo.choice = .crop(.full) }
        return .imported(photo)
    }

    /// Pixel size with EXIF orientation applied (portrait photos report swapped dimensions).
    public static func orientedPixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// A small preview image for grids and the filmstrip (orientation applied).
    public static func thumbnail(of url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }
}
