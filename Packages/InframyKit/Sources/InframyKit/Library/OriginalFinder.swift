import AppKit
import Foundation
import Photos
import Vision

/// Finds the full-size original behind a reduced copy (e.g. a 2048×1152 16:9 crop saved back into Photos by the old
/// SmartThings routine). Everything is local and read-only:
/// 1. Candidates: every photo in the library big enough for the TV (no screenshots).
/// 2. Shortlist: Vision feature prints (cached on disk by asset id + modification date), plus any candidate taken at
///    the same moment as the copy (exports often keep the capture date).
/// 3. Confirm: `SubImageMatcher` checks the copy really is a crop of the candidate, and recovers that crop.
public enum OriginalFinder {
    public struct Match: Sendable, Equatable, Identifiable {
        public let copyAssetID: String
        public let originalAssetID: String
        public let originalName: String
        /// The copy's crop within the original: the crop Matt chose back then.
        public let crop: NormalizedRect
        public let score: Double
        public var id: String { copyAssetID }
    }

    public struct Progress: Sendable, Equatable {
        public let phase: String
        public let done: Int
        public let total: Int

        public init(phase: String, done: Int, total: Int) {
            self.phase = phase
            self.done = done
            self.total = total
        }
    }

    /// How many fingerprint neighbours get the (slower) crop check.
    static let shortlistSize = 15

    public static func find(copies copyIDs: [String], cacheURL: URL,
                            progress: @escaping @Sendable (Progress) -> Void) async -> [Match] {
        guard PhotosAlbumSync.isAuthorized, !copyIDs.isEmpty else { return [] }

        // 1. Candidates.
        let copySet = Set(copyIDs)
        var candidates: [PHAsset] = []
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        PHAsset.fetchAssets(with: options).enumerateObjects { a, _, _ in
            let long = max(a.pixelWidth, a.pixelHeight), short = min(a.pixelWidth, a.pixelHeight)
            guard long >= Panel.width, short >= Panel.height, !copySet.contains(a.localIdentifier),
                  !a.mediaSubtypes.contains(.photoScreenshot) else { return }
            candidates.append(a)
        }
        let copies = PHAsset.fetchAssets(withLocalIdentifiers: copyIDs, options: nil)
        var copyAssets: [PHAsset] = []
        copies.enumerateObjects { a, _, _ in copyAssets.append(a) }

        // 2. Fingerprints (cached).
        var cache = FeaturePrintCache(url: cacheURL)
        var prints: [(asset: PHAsset, print: VNFeaturePrintObservation)] = []
        for (i, asset) in candidates.enumerated() {
            if i % 50 == 0 { progress(Progress(phase: "Scanning your library", done: i, total: candidates.count)) }
            if Task.isCancelled { return [] }
            let key = FeaturePrintCache.key(asset)
            if let fp = cache.get(key) {
                prints.append((asset, fp))
            } else if let image = await image(of: asset, maxPixel: 300, network: false), let fp = featurePrint(image) {
                cache.set(key, fp)
                prints.append((asset, fp))
            }
        }
        cache.save()

        // 3. Shortlist and confirm, one copy at a time.
        var matches: [Match] = []
        var previews: [String: CGImage] = [:]
        for (i, copy) in copyAssets.enumerated() {
            progress(Progress(phase: "Matching", done: i, total: copyAssets.count))
            if Task.isCancelled { break }
            guard let copyImage = await image(of: copy, maxPixel: 320, network: true),
                  let copyPrint = featurePrint(copyImage) else { continue }

            var scored: [(asset: PHAsset, distance: Float)] = []
            for c in prints {
                var d: Float = 0
                if (try? copyPrint.computeDistance(&d, to: c.print)) != nil { scored.append((c.asset, d)) }
            }
            scored.sort { $0.distance < $1.distance }
            var shortlist = scored.prefix(shortlistSize).map(\.asset)
            if let taken = copy.creationDate {
                for c in candidates where !shortlist.contains(c) {
                    if let t = c.creationDate, abs(t.timeIntervalSince(taken)) < 2 { shortlist.insert(c, at: 0) }
                }
            }

            var best: Match?
            for candidate in shortlist {
                let id = candidate.localIdentifier
                if previews[id] == nil { previews[id] = await image(of: candidate, maxPixel: 640, network: true) }
                guard let preview = previews[id] else { continue }
                // Taken at the very same second: strong evidence on its own, so a weaker crop score is enough
                // (edited copies, heavy toning).
                let sameMoment = candidate.creationDate.flatMap { t in copy.creationDate.map { abs(t.timeIntervalSince($0)) < 2 } } ?? false
                let threshold = sameMoment ? 0.75 : SubImageMatcher.threshold
                guard let r = SubImageMatcher.matchCrop(original: preview, tvImage: copyImage), r.score >= threshold,
                      case .crop(let rect) = r.choice else { continue }
                if r.score > (best?.score ?? 0) {
                    best = Match(copyAssetID: copy.localIdentifier, originalAssetID: id,
                                 originalName: PhotosAlbumSync.displayName(of: candidate), crop: rect, score: r.score)
                }
                if r.score > 0.97 { break }   // unmistakable
            }
            if let best { matches.append(best) }
        }
        // 4. Deeper pass for copies still unmatched: every full-size photo from the two weeks before the copy's date
        //    through the day after, previews downloaded from iCloud if needed, all checked directly (no shortlist).
        let found = Set(matches.map(\.copyAssetID))
        let leftovers = copyAssets.filter { !found.contains($0.localIdentifier) && $0.creationDate != nil }
        for (i, copy) in leftovers.enumerated() {
            if Task.isCancelled { break }
            guard let taken = copy.creationDate,
                  let copyImage = await image(of: copy, maxPixel: 320, network: true) else { continue }
            let window = candidates.filter { c in
                guard let t = c.creationDate else { return false }
                return t > taken.addingTimeInterval(-14 * 86400) && t < taken.addingTimeInterval(86400)
            }
            var best: Match?
            for (j, candidate) in window.enumerated() {
                if Task.isCancelled { break }
                progress(Progress(phase: "Looking closer (\(i + 1) of \(leftovers.count))", done: j, total: window.count))
                let id = candidate.localIdentifier
                if previews[id] == nil { previews[id] = await image(of: candidate, maxPixel: 640, network: true) }
                guard let preview = previews[id],
                      let r = SubImageMatcher.match(original: preview, tvImage: copyImage),
                      case .crop(let rect) = r.choice, r.score > (best?.score ?? 0) else { continue }
                best = Match(copyAssetID: copy.localIdentifier, originalAssetID: id,
                             originalName: PhotosAlbumSync.displayName(of: candidate), crop: rect, score: r.score)
                if r.score > 0.97 { break }
            }
            if let best { matches.append(best) }
        }
        progress(Progress(phase: "Done", done: copyAssets.count, total: copyAssets.count))
        return matches
    }

    /// An oriented preview of an asset. `network: false` skips photos whose previews would have to download.
    static func image(of asset: PHAsset, maxPixel: CGFloat, network: Bool) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: maxPixel, height: maxPixel),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                cont.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.first
    }
}

/// Feature prints keyed by asset id + modification date, archived to one file.
struct FeaturePrintCache {
    let url: URL
    private var entries: [String: Data] = [:]
    private var dirty = false

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let dict = try? PropertyListDecoder().decode([String: Data].self, from: data) { entries = dict }
    }

    static func key(_ asset: PHAsset) -> String {
        "\(asset.localIdentifier)|\(Int(asset.modificationDate?.timeIntervalSince1970 ?? 0))"
    }

    func get(_ key: String) -> VNFeaturePrintObservation? {
        entries[key].flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0) }
    }

    mutating func set(_ key: String, _ value: VNFeaturePrintObservation) {
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true) {
            entries[key] = data
            dirty = true
        }
    }

    func save() {
        guard dirty else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PropertyListEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

extension PhotosAlbumSync {
    /// Imports a full-size original in place of a reduced copy in the album. The library photo stays tied to the
    /// copy's album entry (so removing the copy from the album still takes it off the TV) but uses the original's
    /// pixels, with the copy's crop as the starting choice. Returns `.duplicate` if the original is already in the
    /// library.
    public static func useOriginal(_ match: OriginalFinder.Match, albumID: String, store: LibraryStore,
                                   library: [LibraryPhoto]) async throws -> LibraryStore.ImportResult {
        guard let original = PHAsset.fetchAssets(withLocalIdentifiers: [match.originalAssetID], options: nil).firstObject,
              let copy = PHAsset.fetchAssets(withLocalIdentifiers: [match.copyAssetID], options: nil).firstObject else {
            throw ImagePipelineError.unreadable("photo no longer in Photos")
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("InframyOriginal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = try await exportBestImage(original, to: temp)
        let result = try store.importPhoto(at: file, copy: true, existing: library)
        guard case .imported(var photo) = result else { return result }
        photo.displayName = match.originalName
        photo.photosLocalIdentifier = match.copyAssetID
        photo.photosAlbumID = albumID
        photo.photosModifiedAt = copy.modificationDate
        photo.photosOriginalID = match.originalAssetID
        // A 16:9 copy's crop is the TV crop Matt chose back then. Any other shape can't be used as-is: start the
        // crop editor centered on where the copy was.
        let cropAspect = match.crop.width * Double(photo.pixelWidth) / (match.crop.height * Double(photo.pixelHeight))
        if abs(cropAspect - Panel.aspect) / Panel.aspect < 0.02 {
            photo.setRecoveredCrop(match.crop)
        } else {
            photo.choice = .undecided
            photo.suggestedCenter = [match.crop.x + match.crop.width / 2, match.crop.y + match.crop.height / 2]
        }
        if let date = original.creationDate { photo.addedAt = date }
        return .imported(photo)
    }
}
