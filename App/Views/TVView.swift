import InframyKit
import SwiftUI

/// What's actually on the TV (My Photos), with thumbnails from the TV itself.
struct TVView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Set<String> = []
    @State private var confirmingDelete = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 18)]

    var body: some View {
        Group {
            switch model.tvState {
            case .connected:
                if model.tvItems.isEmpty {
                    ContentUnavailableView("Nothing in My Photos", systemImage: "photo.artframe",
                                           description: Text("Photos you send from the Library show up here."))
                } else {
                    grid
                }
            case .searching(let message):
                ProgressView(message).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable(let message):
                ContentUnavailableView {
                    Label("Can't reach the TV", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await model.connect() } }
                    Button("Wake TV") { model.wake() }
                }
            }
        }
        .navigationTitle("On the TV")
        .navigationSubtitle(model.tvState.isConnected ? "\(model.tvItems.count) in My Photos" : "")
        .toolbar {
            ToolbarItemGroup {
                ShuffleControl()
                Button { Task { await model.refreshTV() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!model.tvState.isConnected || model.isRefreshingTV)
                Button { if let id = selection.first { Task { await model.show(id) } } } label: {
                    Label("Show Now", systemImage: "play.rectangle")
                }
                .disabled(selection.count != 1)
                .help("Display the selected photo on the TV now")
                Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .disabled(selection.isEmpty)
                    .help("Delete the selected photos from the TV")
            }
        }
        .onDeleteCommand { if !selection.isEmpty { confirmingDelete = true } }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete from TV", role: .destructive) {
                let ids = selection
                selection = []
                Task { await model.deleteFromTV(ids) }
            }
        } message: {
            Text(deleteMessage)
        }
    }

    private var grid: some View {
        ScrollIfLive {
          VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(model.tvItems, id: \.contentID) { item in
                    TVTile(item: item, selected: selection.contains(item.contentID),
                           isCurrent: model.slideshow?.currentContentID == item.contentID)
                        .onTapGesture { toggle(item.contentID) }
                        .contextMenu {
                            Button("Show Now") { Task { await model.show(item.contentID) } }
                            if let photo = model.photo(forTVItem: item.contentID) {
                                Button("Open in Crop Editor") { model.editingPhotoID = photo.id }
                            }
                            Divider()
                            Button("Delete from TV…", role: .destructive) {
                                if !selection.contains(item.contentID) { selection = [item.contentID] }
                                confirmingDelete = true
                            }
                        }
                }
            }
            .padding(24)
          }
        }
    }

    private func toggle(_ id: String) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = selection == [id] ? [] : [id]
        }
    }

    private var unknownSelected: [String] {
        selection.filter { model.photo(forTVItem: $0) == nil }.sorted()
    }

    private var deleteTitle: String {
        "Delete \(selection.count) photo\(selection.count == 1 ? "" : "s") from the TV?"
    }

    private var deleteMessage: String {
        var text = "This can't be undone. Library copies stay in Inframy."
        if !unknownSelected.isEmpty {
            text += "\n\nAdded outside Inframy: \(unknownSelected.joined(separator: ", ")). These may be photos you added another way."
        }
        return text
    }
}

struct TVTile: View {
    @Environment(AppModel.self) private var model
    let item: ContentItem
    let selected: Bool
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = model.tvThumbnails[item.contentID] {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                if isCurrent {
                    Label("Showing", systemImage: "tv").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule()).padding(6)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accentColor : .black.opacity(0.08), lineWidth: selected ? 3 : 1)
            }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
            HStack(spacing: 6) {
                Text(model.photo(forTVItem: item.contentID)?.displayName ?? item.contentID)
                    .font(.callout).lineLimit(1)
                Spacer()
                if model.photo(forTVItem: item.contentID) == nil {
                    Text("added outside Inframy").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(item.contentID).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Shuffle on/off and interval for My Photos.
struct ShuffleControl: View {
    @Environment(AppModel.self) private var model
    static let intervals: [(Int, String)] = [(3, "3 minutes"), (15, "15 minutes"), (60, "1 hour"), (720, "12 hours"), (1440, "1 day")]

    var body: some View {
        Menu {
            if model.tvItems.count < 2 {
                Text("Shuffle needs at least 2 photos (a 1-photo shuffle wedges this TV)")
            }
            Section("Shuffle My Photos") {
                ForEach(Self.intervals, id: \.0) { minutes, title in
                    Button {
                        Task { await model.setShuffle(on: true, minutes: minutes) }
                    } label: {
                        if model.slideshow?.intervalMinutes == minutes { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
            }
            .disabled(model.tvItems.count < 2)
            Divider()
            Button("Turn Off") { Task { await model.setShuffle(on: false) } }
                .disabled(model.slideshow?.isOn != true)
        } label: {
            Label(title, systemImage: model.slideshow?.isOn == true ? "shuffle.circle.fill" : "shuffle.circle")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!model.tvState.isConnected)
        .help("TV slideshow for My Photos")
    }

    private var title: String {
        guard let minutes = model.slideshow?.intervalMinutes else { return "Shuffle off" }
        let label = Self.intervals.first { $0.0 == minutes }?.1 ?? "\(minutes) min"
        return "Every \(label)"
    }
}

struct SendQueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Send Queue").font(.headline)
                Spacer()
                Button("Clear Finished") { model.clearFinishedJobs() }
                    .disabled(!model.jobs.contains(where: \.isFinished))
                    .controlSize(.small)
            }
            .padding(12)
            Divider()
            if model.jobs.isEmpty {
                Text("Nothing queued. Accept crops in the Library, then press Send.")
                    .font(.callout).foregroundStyle(.secondary).padding(16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.jobs) { job in
                            HStack(spacing: 10) {
                                icon(job.stage).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(job.name).lineLimit(1)
                                    Text(text(job.stage)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                            }
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 320)
            }
        }
    }

    @ViewBuilder
    private func icon(_ stage: AppModel.SendJob.Stage) -> some View {
        switch stage {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .rendering, .uploading, .replacing: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func text(_ stage: AppModel.SendJob.Stage) -> String {
        switch stage {
        case .waiting: return "Waiting"
        case .rendering: return "Rendering 3840×2160…"
        case .uploading: return "Uploading…"
        case .replacing: return "Removing the old version from the TV…"
        case .done(let id): return "On the TV as \(id)"
        case .failed(let message): return message
        }
    }
}
