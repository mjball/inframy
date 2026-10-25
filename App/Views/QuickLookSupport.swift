import InframyKit
import AppKit
import Foundation

/// Files for Quick Look. Library photos preview their original; TV photos with no library original preview the TV's
/// thumbnail, written to a temp file.
enum QuickLookFiles {
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("InframyQuickLook")

    @MainActor
    static func url(forTVItem id: String, model: AppModel) -> URL? {
        if let photo = model.photo(forTVItem: id), let url = model.url(for: photo) { return url }
        guard let image = model.tvThumbnails[id], let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(ContentItem.fileName(for: id)).jpg")
        try? jpeg.write(to: url, options: .atomic)
        return url
    }
}
