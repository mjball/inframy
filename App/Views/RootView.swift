import InframyKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingFileImporter = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingQueue = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Section("Inframy") {
                    Label {
                        HStack {
                            Text("Library")
                            Spacer()
                            if needsCrop > 0 { CountBadge(count: needsCrop, color: .orange) }
                        }
                    } icon: { Image(systemName: "photo.stack") }
                        .tag(AppModel.Section.library)
                    Label {
                        HStack {
                            Text("On the TV")
                            Spacer()
                            if model.tvState.isConnected { CountBadge(count: model.tvItems.count, color: .secondary) }
                        }
                    } icon: { Image(systemName: "photo.artframe") }
                        .tag(AppModel.Section.tv)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { TVStatusCard().padding(10) }
        } detail: {
            Group {
                if let id = model.editingPhotoID, model.photos.contains(where: { $0.id == id }) {
                    CropEditorView(photoID: id)
                        .id(id)
                } else {
                    switch model.section {
                    case .library: LibraryView()
                    case .tv: TVView()
                    }
                }
            }
            .toolbar { toolbar }
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.importFiles(urls, copy: false) } }
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task { await importPicked(items) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importPhotos)) { _ in showingFileImporter = true }
        .alert("Inframy", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var needsCrop: Int { model.photos.filter { $0.status == .needsCrop }.count }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("From Files…") { showingFileImporter = true }
                PhotosPicker("From Photos…", selection: $pickerItems, matching: .images)
                if model.albumSyncEnabled {
                    Divider()
                    Button("Sync \u{201C}\(model.albumName)\u{201D} Album") { Task { await model.syncAlbum(userInitiated: true) } }
                }
            } label: {
                Label("Import", systemImage: "plus")
            } primaryAction: {
                showingFileImporter = true
            }
            .help("Import photos (or drag them in from Finder or Photos)")

            Button {
                showingQueue.toggle()
            } label: {
                Label("Queue", systemImage: activeJobs > 0 ? "arrow.up.circle.fill" : "arrow.up.circle")
                    .symbolEffect(.pulse, isActive: activeJobs > 0)
            }
            .help("Send queue")
            .popover(isPresented: $showingQueue, arrowEdge: .bottom) { SendQueueView().frame(width: 340) }

            Button {
                model.send(model.readyToSend.map(\.id))
                showingQueue = true
            } label: {
                Label(sendTitle, systemImage: "paperplane.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.readyToSend.isEmpty || !model.tvState.isConnected)
            .help("Render and upload every photo whose crop you've accepted")
        }
    }

    private var activeJobs: Int { model.jobs.filter { !$0.isFinished }.count }

    private var sendTitle: String {
        let n = model.readyToSend.count
        return n == 0 ? "Send" : "Send \(n)"
    }

    private func importPicked(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        for item in items {
            if let file = try? await item.loadTransferable(type: PickedImageFile.self) { urls.append(file.url) }
        }
        await model.importFiles(urls, copy: true)
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }
}

/// A photo handed over by the Photos picker, copied to a temp folder we own.
struct PickedImageFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("InframyPick-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedImageFile(url: dest)
        }
    }
}

struct CountBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color == .secondary ? Color.secondary : color)
    }
}

/// Bottom of the sidebar: which TV, and whether it's reachable.
struct TVStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .shadow(color: dotColor.opacity(0.6), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            if !isSnapshot { menu }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6)))
    }

    @Environment(\.isSnapshot) private var isSnapshot

    private var menu: some View {
            Menu {
                Button("Reconnect") { Task { await model.connect() } }
                Button("Wake TV") { model.wake() }
                    .disabled(SavedTV.load()?.wifiMAC == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
    }

    private var dotColor: Color {
        switch model.tvState {
        case .connected: return .green
        case .searching: return .yellow
        case .unavailable: return .red
        }
    }

    private var title: String {
        switch model.tvState {
        case .connected: return model.tvName
        case .searching: return "Connecting…"
        case .unavailable: return "TV not reachable"
        }
    }

    private var subtitle: String {
        switch model.tvState {
        case .connected(let info, let version):
            let shuffle = model.slideshow.flatMap { $0.intervalMinutes.map { "shuffle \($0) min" } } ?? "shuffle off"
            return "\(info.host) · API \(version) · \(shuffle)"
        case .searching(let message): return message
        case .unavailable(let message): return message
        }
    }
}
