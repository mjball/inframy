import CoreGraphics
import Foundation

/// Recognizes library photos that are already on the TV (SPEC §6). Matching changes only Inframy's own records,
/// never the TV, so it runs automatically; "Not the same photo" undoes it.
public enum Recognition {
    public struct Match: Sendable, Equatable {
        public let photoID: UUID
        public let contentID: String
        public let choice: LibraryPhoto.Choice
        public let score: Double
    }

    /// Best one-to-one matches between unmatched TV items and photos not yet on the TV.
    /// - Parameters:
    ///   - originals: oriented previews of the candidate photos (~512 px is plenty).
    ///   - tvImages: the TV's thumbnails of items no library photo accounts for.
    public static func match(photos: [LibraryPhoto], originals: [UUID: CGImage],
                             tvImages: [String: CGImage]) -> [Match] {
        var candidates: [Match] = []
        for photo in photos where photo.tvContentID == nil && photo.choice != .skip {
            guard let original = originals[photo.id] else { continue }
            let rejected = Set(photo.notSameAs ?? [])
            for (cid, tv) in tvImages where !rejected.contains(cid) {
                if let r = SubImageMatcher.match(original: original, tvImage: tv) {
                    candidates.append(Match(photoID: photo.id, contentID: cid, choice: r.choice, score: r.score))
                }
            }
        }
        candidates.sort { ($0.score, $1.contentID) > ($1.score, $0.contentID) }
        var usedPhotos = Set<UUID>(), usedTV = Set<String>()
        var result: [Match] = []
        for m in candidates where !usedPhotos.contains(m.photoID) && !usedTV.contains(m.contentID) {
            usedPhotos.insert(m.photoID)
            usedTV.insert(m.contentID)
            result.append(m)
        }
        return result
    }

    /// The photo marked as on the TV. An undecided photo takes the crop recovered from the TV copy; a photo with a
    /// crop already chosen keeps it (and shows as changed if it differs from what's on the TV).
    public static func apply(_ match: Match, to photo: LibraryPhoto) -> LibraryPhoto {
        var p = photo
        let tvVersion: LibraryPhoto = {
            var v = photo
            v.choice = match.choice
            return v
        }()
        if p.choice == .undecided { p.choice = match.choice }
        p.tvContentID = match.contentID
        p.uploadedRenderKey = tvVersion.renderKey
        p.onTVSince = p.onTVSince ?? Date()
        p.recognizedOnTV = true
        return p
    }

    /// "Not the same photo": back to needing a crop, and never paired with that TV item again.
    public static func reject(_ photo: LibraryPhoto) -> LibraryPhoto {
        var p = photo
        if let cid = p.tvContentID { p.notSameAs = (p.notSameAs ?? []) + [cid] }
        if p.recognizedOnTV == true, !p.isPanelShaped { p.choice = .undecided }
        p.tvContentID = nil
        p.uploadedRenderKey = nil
        p.onTVSince = nil
        p.recognizedOnTV = nil
        return p
    }
}
