import InframyKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
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
            .alert(massRemovalTitle, isPresented: Binding(get: { model.massRemovalPrompt != nil }, set: { _ in })) {
                Button("Remove from TV", role: .destructive) { Task { await model.resolveMassRemoval(remove: true) } }
                Button("Keep Them") { Task { await model.resolveMassRemoval(remove: false) } }
            } message: {
                Text("They're no longer in \u{201C}\(model.massRemovalPrompt?.albumTitle ?? "the album")\u{201D}. If that's a Photos hiccup (for example while iCloud is syncing), keep them. Kept photos stay on the TV and in the Library but stop following the album.")
            }
        }
        .alert("Inframy", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var massRemovalTitle: String {
        let n = model.massRemovalPrompt?.ids.count ?? 0
        return "\(n) photos left the album. Remove them from the TV?"
    }

    private var needsCrop: Int { model.photos.filter { $0.status == .needsCrop }.count }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            AlbumToolbarMenu()

            Button {
                showingQueue.toggle()
            } label: {
                Label("Queue", systemImage: activeJobs > 0 ? "arrow.up.circle.fill" : "arrow.up.circle")
                    .symbolEffect(.pulse, isActive: activeJobs > 0)
            }
            .help("Send queue")
            .popover(isPresented: $showingQueue, arrowEdge: .bottom) { SendQueueView().frame(width: 340) }

            Button {
                let ids = model.readyToSend.map(\.id)
                model.send(ids)
                showingQueue = true
            } label: {
                Label(sendTitle, systemImage: "paperplane.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.readyToSend.isEmpty)
            .help("Render and upload every photo whose crop you've accepted. If the TV is asleep, they go out when it wakes.")
        }
    }

    private var activeJobs: Int { model.jobs.filter { !$0.isFinished }.count }

    private var sendTitle: String {
        let n = model.readyToSend.count
        return n == 0 ? "Send" : "Send \(n)"
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
                Button("Connect to TV") { Task { await model.connectNow() } }
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
        case .away: return .secondary
        }
    }

    private var title: String {
        switch model.tvState {
        case .connected: return model.tvName
        case .searching: return "Connecting…"
        case .unavailable: return "TV not reachable"
        case .away: return "Away from home"
        }
    }

    private var subtitle: String {
        switch model.tvState {
        case .connected(let info, let version):
            let shuffle = model.slideshow.flatMap { $0.intervalMinutes.map { "shuffle every \($0) min on screen" } } ?? "shuffle off"
            return "\(info.host) · API \(version) · \(shuffle)"
        case .searching(let message): return message
        case .unavailable(let message): return message
        case .away: return "Connects when you're back on the TV's network"
        }
    }
}
