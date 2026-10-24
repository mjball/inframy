import AppKit
import CoreImage
import InframyKit
import QuickLook
import SwiftUI

/// The crop editor (SPEC §4). The 16:9 frame never changes shape; the photo moves and scales under it.
/// Matt always makes the call: the computer-vision suggestion only sets where the frame starts.
struct CropEditorView: View {
    @Environment(AppModel.self) private var model
    let photoID: UUID

    @State private var preview: CGImage?
    @State private var geometry: CropGeometry?
    @State private var suggestion: CGPoint?
    @State private var showWall = false
    @State private var quickLookURL: URL?
    @FocusState private var focused: Bool

    private var photo: LibraryPhoto? { model.photos.first { $0.id == photoID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color(white: 0.12)
                if let preview, let geometry {
                    CropCanvas(image: preview, geometry: Binding(get: { geometry }, set: { self.geometry = $0 }),
                               suggestion: suggestion, wallPreview: showWall)
                } else {
                    ProgressView()
                }
            }
            Divider()
            Filmstrip(current: photoID)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            let step = press.modifiers.contains(.shift) ? 0.1 : 0.02
            switch press.key {
            case .upArrow: geometry?.nudge(dx: 0, dy: -step)
            case .downArrow: geometry?.nudge(dx: 0, dy: step)
            case .leftArrow: geometry?.nudge(dx: -step, dy: 0)
            default: geometry?.nudge(dx: step, dy: 0)
            }
            return .handled
        }
        .onKeyPress(.escape) { model.editingPhotoID = nil; return .handled }
        .onKeyPress(.space) {
            // Space is Quick Look everywhere in Inframy; P toggles the "as on the wall" preview.
            quickLookURL = photo.flatMap { model.url(for: $0) }
            return .handled
        }
        .quickLookPreview($quickLookURL)
        .onKeyPress(characters: .init(charactersIn: "rRsSpP+=-_")) { press in
            switch press.characters {
            case "p", "P": showWall.toggle()
            case "r", "R": reset()
            case "s", "S": skip()
            case "+", "=": geometry?.zoom(by: 1.15)
            default: geometry?.zoom(by: 1 / 1.15)
            }
            return .handled
        }
        .task(id: photoID) { await load() }
        .onAppear { focused = true }
        .navigationTitle(photo?.displayName ?? "Crop")
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Button { model.editingPhotoID = nil } label: { Label("Library", systemImage: "chevron.left") }
                .help("Back to the library (Esc)")
            VStack(alignment: .leading, spacing: 1) {
                Text(photo?.displayName ?? "").font(.headline).lineLimit(1)
                if let photo { Text("\(photo.pixelWidth) × \(photo.pixelHeight)").font(.caption).foregroundStyle(.secondary) }
            }
            if photo?.choice == .skip {
                Label("Skipped", systemImage: "eye.slash").font(.callout).foregroundStyle(.secondary)
                    .help("This photo won't be sent. Accept a crop to send it after all.")
            }
            Spacer()
            Toggle("Sharpen", isOn: Binding(
                get: { photo?.sharpen ?? false },
                set: { on in if var p = photo { p.sharpen = on ? true : nil; model.update(p) } }))
                .toggleStyle(.checkbox)
                .help("Light sharpening after resizing. Off by default; judge it on the TV.")
            Button("Reset") { reset() }
                .help("Back to the suggested position (R)")
            Button("Skip") { skip() }
                .help("Don't send this photo; go to the next one (S)")
            Button(acceptTitle) { accept() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help("Use this and go to the next photo (Return)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var acceptTitle: String {
        model.nextUndecided(after: photoID) == nil ? "Accept" : "Accept & Next"
    }

    // MARK: Actions

    private func load() async {
        guard let photo, let url = model.url(for: photo) else { return }
        let image = await Task.detached { LibraryStore.thumbnail(of: url, maxPixel: 2560) }.value
        preview = image
        if let c = photo.suggestedCenter, c.count == 2 { suggestion = CGPoint(x: c[0], y: c[1]) }
        if case .crop(let rect) = photo.choice {
            geometry = CropGeometry(imageSize: photo.imageSize, rect: rect)
        } else {
            geometry = CropGeometry(imageSize: photo.imageSize, center: suggestion ?? CGPoint(x: 0.5, y: 0.5))
        }
        // Compute the hint once per photo, off the main thread, and only move an untouched frame.
        if photo.suggestedCenter == nil, let image {
            let center = await Task.detached { CropSuggestion.center(for: CIImage(cgImage: image)) }.value
            var updated = photo
            updated.suggestedCenter = center.map { [$0.x, $0.y] } ?? [0.5, 0.5]
            model.update(updated)
            suggestion = center
            if case .undecided = photo.choice, let center {
                geometry = CropGeometry(imageSize: photo.imageSize, center: center)
            }
        }
    }

    private func reset() {
        guard let photo else { return }
        geometry = CropGeometry(imageSize: photo.imageSize, center: suggestion ?? CGPoint(x: 0.5, y: 0.5))
    }

    private func accept() {
        if let geometry { model.setChoice(.crop(geometry.rect), for: photoID) }
        model.editingPhotoID = model.nextUndecided(after: photoID)
    }

    private func skip() {
        model.setChoice(.skip, for: photoID)
        model.editingPhotoID = model.nextUndecided(after: photoID)
    }
}

/// Draws the photo under a fixed 16:9 frame inside a white TV-like bezel, and turns mouse input into pan/zoom.
struct CropCanvas: View {
    @Environment(\.isSnapshot) private var isSnapshot
    let image: CGImage
    @Binding var geometry: CropGeometry
    let suggestion: CGPoint?
    let wallPreview: Bool

    var body: some View {
        GeometryReader { geo in
            let frame = Self.frameRect(in: geo.size, wall: wallPreview)
            let bezel = frame.width * 0.022
            ZStack(alignment: .topLeading) {
                cropLayers(frame: frame)
                // The TV: white bezel with a soft shadow, like Matt's Frame on the wall.
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color(white: 0.96), lineWidth: bezel)
                    .frame(width: frame.width + bezel * 2, height: frame.height + bezel * 2)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    .offset(x: frame.minX - bezel, y: frame.minY - bezel)
                    .allowsHitTesting(false)
                if !wallPreview { thirds(frame: frame) }
            }
            .overlay {
                if !isSnapshot {
                    MouseCatcher(
                        onDrag: { delta in geometry.pan(by: delta, frameSize: frame.size) },
                        onZoom: { factor, point in
                            let anchor = CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
                            geometry.zoom(by: factor, anchor: CGPoint(x: min(max(anchor.x, 0), 1), y: min(max(anchor.y, 0), 1)))
                        })
                }
            }
        }
        .clipped()
    }

    /// The largest 16:9 rect that fits with breathing room for the bezel.
    static func frameRect(in size: CGSize, wall: Bool) -> CGRect {
        let pad: CGFloat = wall ? 24 : 56
        let avail = CGSize(width: max(size.width - pad * 2, 10), height: max(size.height - pad * 2, 10))
        var w = avail.width
        var h = w / Panel.aspect
        if h > avail.height { h = avail.height; w = h * Panel.aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    @ViewBuilder
    private func cropLayers(frame: CGRect) -> some View {
        let r = geometry.rect
        let w = frame.width / r.width
        let h = frame.height / r.height
        let origin = CGPoint(x: frame.minX - r.x * w, y: frame.minY - r.y * h)
        let picture = Image(decorative: image, scale: 1).resizable().interpolation(.high)
        if wallPreview {
            // Only what will be on the wall.
            picture
                .frame(width: w, height: h)
                .offset(x: origin.x, y: origin.y)
                .mask(alignment: .topLeading) {
                    Rectangle().frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                }
        } else {
            // The whole photo at full quality, with a dark scrim over everything outside the frame, so you can
            // still see what you're leaving out. (A faded copy looked muddy and bled behind the toolbar.)
            picture
                .frame(width: w, height: h)
                .offset(x: origin.x, y: origin.y)
            Scrim(cutout: frame)
                .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
        }
        if let s = suggestion, !wallPreview {
            // The hint: a small ring where computer vision thinks the subject is.
            let p = CGPoint(x: origin.x + s.x * w, y: origin.y + s.y * h)
            Circle()
                .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                .background(Circle().fill(.black.opacity(0.15)))
                .frame(width: 16, height: 16)
                .offset(x: p.x - 8, y: p.y - 8)
                .help("Suggested subject")
                .allowsHitTesting(false)
        }
    }

    private func thirds(frame: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = frame.minX + frame.width * CGFloat(i) / 3
                let y = frame.minY + frame.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
                p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.18), lineWidth: 0.5)
        .allowsHitTesting(false)
    }
}

/// AppKit view for the input SwiftUI doesn't expose well on macOS: drag to pan, mouse wheel and pinch to zoom,
/// two-finger trackpad scroll to pan.
struct MouseCatcher: NSViewRepresentable {
    let onDrag: (CGSize) -> Void
    let onZoom: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onDrag = onDrag
        v.onZoom = onZoom
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.onDrag = onDrag
        v.onZoom = onZoom
    }

    final class CatcherView: NSView {
        var onDrag: ((CGSize) -> Void)?
        var onZoom: ((Double, CGPoint) -> Void)?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) { NSCursor.closedHand.push() }
        override func mouseUp(with event: NSEvent) { NSCursor.pop() }

        override func mouseDragged(with event: NSEvent) {
            onDrag?(CGSize(width: event.deltaX, height: event.deltaY))
        }

        override func scrollWheel(with event: NSEvent) {
            if event.hasPreciseScrollingDeltas {
                // Trackpad: two-finger scroll pans (natural direction).
                onDrag?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            } else {
                // Mouse wheel: zoom around the pointer.
                let point = convert(event.locationInWindow, from: nil)
                onZoom?(pow(1.06, event.scrollingDeltaY), point)
            }
        }

        override func magnify(with event: NSEvent) {
            onZoom?(1 + event.magnification, convert(event.locationInWindow, from: nil))
        }
    }
}

/// Every photo in the library, so you can jump around; undecided ones are marked.
struct Filmstrip: View {
    @Environment(AppModel.self) private var model
    let current: UUID

    var body: some View {
        ScrollViewReader { proxy in
            ScrollIfLive(axes: .horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(model.photos) { photo in
                        FilmstripCell(photo: photo, isCurrent: photo.id == current)
                            .id(photo.id)
                            .onTapGesture { model.editingPhotoID = photo.id }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(height: 92)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
        .background(.bar)
    }
}

struct FilmstripCell: View {
    @Environment(AppModel.self) private var model
    let photo: LibraryPhoto
    let isCurrent: Bool
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(photo.status == .skipped ? 0.4 : 1)
            Circle()
                .fill(photo.status == .needsCrop ? Color.orange : photo.status == .onTV ? .green : .blue)
                .frame(width: 8, height: 8)
                .padding(4)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2.5).padding(-3))
        .task(id: photo.id) { image = await model.thumbnail(for: photo) }
    }
}

/// Everything except `cutout` (even-odd fill): the crop editor's dimming outside the frame.
struct Scrim: Shape {
    let cutout: CGRect

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addRect(rect)
        p.addRect(cutout)
        return p
    }
}
