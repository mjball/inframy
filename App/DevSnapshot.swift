import AppKit
import InframyKit
import SwiftUI

/// Development only: `INFRAMY_SNAPSHOT=/path/out.png` renders the current screen with SwiftUI's ImageRenderer
/// (an app can't screenshot itself without Screen Recording permission) and quits.
/// AppKit-backed pieces (the crop editor's mouse layer, menus) don't render, which is fine for checking layout.
enum DevSnapshot {
    @MainActor
    static func scheduleIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["INFRAMY_SNAPSHOT"] else { return }
        let delay = Double(env["INFRAMY_SNAPSHOT_DELAY"] ?? "") ?? 8
        let dark = env["INFRAMY_SNAPSHOT_DARK"] == "1"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let content = SnapshotFrame(dark: dark).environment(model)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}

/// A stand-in for the window: sidebar + the current detail screen, at a typical window size.
private struct SnapshotFrame: View {
    @Environment(AppModel.self) private var model
    let dark: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inframy").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                Label("Library", systemImage: "photo.stack").padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.section == .library ? Color.accentColor.opacity(0.2) : .clear))
                Label("On the TV", systemImage: "photo.artframe").padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.section == .tv ? Color.accentColor.opacity(0.2) : .clear))
                Spacer()
                TVStatusCard()
            }
            .padding(12)
            .frame(width: 230)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            Divider()
            Group {
                if let id = model.editingPhotoID, let photo = model.photos.first(where: { $0.id == id }),
                   let url = model.url(for: photo), let image = LibraryStore.thumbnail(of: url, maxPixel: 2560) {
                    // ImageRenderer doesn't run .task, so load synchronously and show the canvas directly.
                    VStack(spacing: 0) {
                        CropCanvas(image: image,
                                   geometry: .constant(CropGeometry(imageSize: photo.imageSize, center: CGPoint(x: 0.5, y: 0.53))),
                                   suggestion: CGPoint(x: 0.47, y: 0.53), wallPreview: false)
                            .background(Color(nsColor: .underPageBackgroundColor))
                        Divider()
                        Filmstrip(current: id)
                    }
                } else if model.section == .library {
                    LibraryView()
                } else {
                    TVView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 1280, height: 800)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.isSnapshot, true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while rendering a dev snapshot: ImageRenderer can't draw scroll views or menus.
    var isSnapshot: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

/// A ScrollView, except in snapshots (ImageRenderer draws a placeholder for scroll views).
struct ScrollIfLive<Content: View>: View {
    @Environment(\.isSnapshot) private var isSnapshot
    var axes: Axis.Set = .vertical
    @ViewBuilder var content: Content

    var body: some View {
        if isSnapshot {
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView(axes, showsIndicators: false) { content }
        }
    }
}
