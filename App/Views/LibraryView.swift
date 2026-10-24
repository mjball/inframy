import InframyKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false
    @State private var selection: Set<UUID> = []

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 18)]

    var body: some View {
        Group {
            if model.photos.isEmpty {
                EmptyLibraryView()
            } else {
                ScrollIfLive {
                    VStack(alignment: .leading, spacing: 24) {
                        section("Needs a crop", photos(.needsCrop), hint: "Pick the 16:9 area for each. Nothing is sent until you do.")
                        section("Ready to send", model.readyToSend, hint: nil)
                        section("On the TV", photos(.onTV), hint: nil)
                        section("Skipped", photos(.skipped), hint: nil)
                        if !model.uncoveredSkipped.isEmpty { TooSmallNote() }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Library")
        .navigationSubtitle(subtitle)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor.opacity(0.06)))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .modifier(PhotoDropTarget(targeted: $dropTargeted))
        .onDeleteCommand { if !selection.isEmpty { model.removeFromLibrary(selection); selection = [] } }
    }

    private var subtitle: String {
        let n = model.photos.count
        let count = "\(n) photo\(n == 1 ? "" : "s")"
        guard let album = model.albumTitle, model.albumID != nil else { return count }
        return "\(count) · synced with \u{201C}\(album)\u{201D}"
    }

    private func photos(_ status: LibraryPhoto.Status) -> [LibraryPhoto] {
        model.photos.filter { $0.status == status }
    }

    @ViewBuilder
    private func section(_ title: String, _ photos: [LibraryPhoto], hint: String?) -> some View {
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.title3.weight(.semibold))
                    Text("\(photos.count)").foregroundStyle(.secondary)
                    if let hint { Text(hint).font(.callout).foregroundStyle(.secondary).padding(.leading, 6) }
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(photos) { photo in
                        PhotoTile(photo: photo, selected: selection.contains(photo.id))
                            .onTapGesture(count: 2) { model.editingPhotoID = photo.id }
                            .onTapGesture { toggle(photo.id) }
                            .contextMenu { menu(for: photo) }
                    }
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    @ViewBuilder
    private func menu(for photo: LibraryPhoto) -> some View {
        Button("Choose Crop…") { model.editingPhotoID = photo.id }
        if photo.recognizedOnTV == true {
            Button("Not the Same Photo") { model.markNotSame(photo.id) }
        }
        Button(photo.status == .skipped ? "Don't Skip" : "Skip") {
            model.setChoice(photo.status == .skipped ? .undecided : .skip, for: photo.id)
        }
        Divider()
        Button("Send to TV") { model.send([photo.id]) }
            .disabled(photo.renderSpec == nil)
        if let url = model.url(for: photo) {
            Button("Show Original in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        Divider()
        let ids = selection.contains(photo.id) ? selection : [photo.id]
        if photo.photosAlbumID != nil, photo.photosAlbumID == model.albumID {
            // The album is the source of truth: removing it here would just bring it back on the next sync.
            Button("To remove, take it out of \u{201C}\(model.albumTitle ?? "the album")\u{201D} in Photos") {}
                .disabled(true)
        } else {
            Button("Remove from Library", role: .destructive) {
                model.removeFromLibrary(ids)
                selection.subtract(ids)
            }
        }
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop photos here").font(.title2.weight(.semibold))
            Text("Drag photos in from Finder or Photos, or use Import (⌘O). Photos need to be at least 3840×2160.\nYou'll pick the 16:9 area for each one; nothing is cropped for you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A library photo: shows the chosen area (or the whole photo while undecided), with a status badge.
struct PhotoTile: View {
    @Environment(AppModel.self) private var model
    let photo: LibraryPhoto
    var selected = false
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image { preview(image) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) { StatusBadge(status: photo.status).padding(6) }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : .black.opacity(0.08), lineWidth: selected ? 3 : 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            HStack {
                Text(photo.displayName).font(.callout).lineLimit(1)
                Spacer()
                if photo.recognizedOnTV == true {
                    Text("Already on your TV").font(.caption).foregroundStyle(.secondary)
                        .help("Inframy recognized this photo on the TV (\(photo.tvContentID ?? "")) and used the crop it has there. Right-click → Not the Same Photo if that's wrong.")
                } else if let id = photo.tvContentID {
                    Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: photo.id) { image = await model.thumbnail(for: photo) }
    }

    @ViewBuilder
    private func preview(_ image: NSImage) -> some View {
        switch photo.choice {
        case .crop(let rect):
            CroppedImage(image: image, rect: rect)
        case .undecided, .skip:
            Image(nsImage: image).resizable().scaledToFit()
                .opacity(photo.status == .skipped ? 0.45 : 1)
        }
    }
}

/// Draws `rect` (normalized) of `image` filling the view.
struct CroppedImage: View {
    let image: NSImage
    let rect: NormalizedRect

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / rect.width
            let h = geo.size.height / rect.height
            Image(nsImage: image)
                .resizable()
                .frame(width: w, height: h)
                .offset(x: -rect.x * w, y: -rect.y * h)
        }
        .clipped()
    }
}

struct StatusBadge: View {
    let status: LibraryPhoto.Status

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(color)
    }

    private var text: String {
        switch status {
        case .needsCrop: return "Needs crop"
        case .readyToSend: return "Ready"
        case .onTV: return "On TV"
        case .changedSinceUpload: return "Changed"
        case .skipped: return "Skipped"
        }
    }

    private var symbol: String {
        switch status {
        case .needsCrop: return "crop"
        case .readyToSend: return "arrow.up.circle"
        case .onTV: return "checkmark.circle.fill"
        case .changedSinceUpload: return "arrow.triangle.2.circlepath"
        case .skipped: return "eye.slash"
        }
    }

    private var color: Color {
        switch status {
        case .needsCrop: return .orange
        case .readyToSend: return .blue
        case .onTV: return .green
        case .changedSinceUpload: return .purple
        case .skipped: return .secondary
        }
    }
}

/// Drops from Finder (file URLs: referenced in place) and Photos (image data: copied into the library).
enum PhotoDrop {
    @MainActor
    static func handle(_ providers: [NSItemProvider], model: AppModel) async {
        var references: [URL] = []
        var copies: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await loadFileURL(provider) {
                references.append(url)
            } else if let url = await copyImage(provider) {
                copies.append(url)
            }
        }
        if !references.isEmpty { await model.importFiles(references, copy: false) }
        if !copies.isEmpty {
            await model.importFiles(copies, copy: true)
            for url in copies { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        }
    }

    @MainActor
    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }

    /// Photos hands out a temporary file (or a file promise); copy it before the handler returns.
    @MainActor
    private static func copyImage(_ provider: NSItemProvider) async -> URL? {
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true }
            ?? UTType.image.identifier
        return await withCheckedContinuation { cont in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else { cont.resume(returning: nil); return }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("InframyDrop-\(UUID().uuidString)")
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.copyItem(at: url, to: dest)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

/// Accepts photo drops (skipped in dev snapshots, which can't render drop targets).
struct PhotoDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if isSnapshot {
            content
        } else {
            content.onDrop(of: [.fileURL, .image], isTargeted: $targeted) { providers in
                Task { await PhotoDrop.handle(providers, model: model) }
                return true
            }
        }
    }
}

/// Album photos that are too small for the TV: a quiet note, with thumbnails on request.
struct TooSmallNote: View {
    @Environment(AppModel.self) private var model
    @State private var expanded = false
    @State private var showingFinder = false
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]

    var body: some View {
        let n = model.uncoveredSkipped.count
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text("These are in \u{201C}\(model.albumTitle ?? "the album")\u{201D} but have fewer pixels than the TV, so they'd look soft. If they're reduced copies, Inframy can look for the full-size originals in your library.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Find Full-Size Originals…") {
                        showingFinder = true
                        if model.originalMatches.isEmpty && !model.isFindingOriginals { model.findOriginals() }
                    }
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(model.uncoveredSkipped) { SkippedTile(photo: $0) }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("\(n) photo\(n == 1 ? "" : "s") in \u{201C}\(model.albumTitle ?? "the album")\u{201D} \(n == 1 ? "is" : "are") too small for the TV (under \(Panel.width)×\(Panel.height))",
                  systemImage: "photo.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        .sheet(isPresented: $showingFinder) { OriginalsSheet().frame(width: 720, height: 560) }
    }
}

/// Finding and reviewing full-size originals for reduced copies.
struct OriginalsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Full-size originals").font(.title3.weight(.semibold))
                Text("Each reduced copy from the album is matched to the photo it was cropped from. Using the original keeps your old crop and doesn't change anything in Photos.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            if model.isFindingOriginals {
                VStack(spacing: 10) {
                    if let p = model.originalProgress, p.total > 0 {
                        ProgressView(value: Double(p.done), total: Double(p.total))
                        Text("\(p.phase): \(p.done.formatted()) of \(p.total.formatted())").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                        Text(model.originalProgress?.phase ?? "Starting").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("The first scan reads a small preview of every photo in your library; later scans are quick.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.originalMatches.isEmpty {
                ContentUnavailableView("No originals found", systemImage: "magnifyingglass",
                                       description: Text("None of the remaining copies matched a full-size photo in your library."))
            } else {
                List(model.originalMatches) { match in
                    HStack(spacing: 14) {
                        AssetThumb(assetID: match.copyAssetID, caption: "Copy in album")
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        AssetThumb(assetID: match.originalAssetID, caption: match.originalName, crop: match.crop)
                        Spacer()
                        Button("Use Original") { Task { await model.useOriginal(match) } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            }
            Divider()
            HStack {
                if model.isFindingOriginals {
                    Button("Stop") { model.cancelFindingOriginals() }
                } else {
                    Button("Search Again") { model.findOriginals() }
                }
                Spacer()
                let n = model.originalMatches.count
                if n > 1 && !model.isFindingOriginals {
                    Button("Use All \(n)") { Task { await model.useAllOriginals() } }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }
}

/// A Photos asset thumbnail, optionally outlining a crop.
struct AssetThumb: View {
    let assetID: String
    let caption: String
    var crop: NormalizedRect? = nil
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .overlay {
                            if let crop {
                                GeometryReader { geo in
                                    Rectangle()
                                        .strokeBorder(Color.yellow, lineWidth: 2)
                                        .frame(width: geo.size.width * crop.width, height: geo.size.height * crop.height)
                                        .offset(x: geo.size.width * crop.x, y: geo.size.height * crop.y)
                                }
                            }
                        }
                }
            }
            .frame(width: 220, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .task(id: assetID) {
            if let cg = await PhotosAlbumSync.thumbnail(assetID: assetID, maxPixel: 440) { image = NSImage(cgImage: cg, size: .zero) }
        }
    }
}

struct SkippedTile: View {
    let photo: PhotosAlbumSync.SkippedPhoto
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(label).font(.caption).lineLimit(1)
            Text("\(photo.width)×\(photo.height)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
        .help(photo.name)
        .task(id: photo.assetID) {
            if let cg = await PhotosAlbumSync.thumbnail(assetID: photo.assetID, maxPixel: 400) {
                image = NSImage(cgImage: cg, size: .zero)
            }
        }
    }

    private var label: String {
        if let name = photo.readableName { return name }
        if let date = photo.created { return date.formatted(date: .abbreviated, time: .shortened) }
        return "Untitled photo"
    }
}
