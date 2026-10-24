import InframyKit
import ServiceManagement
import SwiftUI

enum Prefs {
    /// The synced Photos album (PhotoKit collection id; survives renames) and its last-known title.
    static let albumID = "albumID"
    static let albumTitle = "albumTitle"
    /// "removeFromTV" (default) or "keep": what happens when a photo leaves the album.
    static let albumRemoval = "albumRemoval"
    static let lastAlbumSync = "lastAlbumSync"
    // Before album ids: enabled flag + name. Migrated on launch.
    static let legacyAlbumSyncEnabled = "albumSyncEnabled"
    static let legacyAlbumName = "albumName"
    static let shuffleMinutes = "shuffleMinutes"
    static let keepShuffleOn = "keepShuffleOn"

    static func register() {
        UserDefaults.standard.register(defaults: [
            shuffleMinutes: 15, keepShuffleOn: true, albumRemoval: "removeFromTV",
        ])
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.shuffleMinutes) private var shuffleMinutes = 15
    @AppStorage(Prefs.keepShuffleOn) private var keepShuffleOn = true
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Photos") {
                AlbumPicker()
            }
            Section("TV") {
                Picker("Shuffle interval when Inframy turns shuffle on", selection: $shuffleMinutes) {
                    ForEach(ShuffleControl.intervals, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Keep the slideshow on", isOn: $keepShuffleOn)
                Text("Whenever the TV is awake, Inframy turns My Photos shuffle back on if it has stopped (2020 Frames sometimes do). The TV's shuffle is what rotates your photos.")
                    .font(.caption).foregroundStyle(.secondary)
                if let tv = SavedTV.load() {
                    LabeledContent("Paired TV", value: "\(tv.name.replacingOccurrences(of: "[TV] ", with: "")) · \(tv.host)")
                    LabeledContent("Model", value: tv.model ?? "?")
                }
            }
            Section("General") {
                Toggle("Open Inframy at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in openAtLogin = LoginItem.set(on) }
                Text("Keeps the menu bar item running, so photos you send while the TV sleeps go out when it wakes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Library") {
                    Button(model.store.directory.path) { NSWorkspace.shared.open(model.store.directory) }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}


enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the resulting state (registration can fail, e.g. for an app run from a build folder).
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        return isEnabled
    }
}

/// Choose the Photos album Inframy keeps the TV in step with.
struct AlbumPicker: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.albumRemoval) private var removal = "removeFromTV"
    @State private var albums: [PhotosAlbumSync.Album] = []
    @State private var loading = false
    @State private var needsAccess = !PhotosAlbumSync.isAuthorized

    var body: some View {
        if needsAccess {
            LabeledContent("Photos album") {
                Button("Allow Access to Photos…") { Task { await load() } }
            }
            Text("Inframy only reads from Photos. It never changes your library or albums.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Photos album", selection: Binding(
                get: { model.albumID ?? "" },
                set: { id in model.chooseAlbum(albums.first { $0.id == id }) })) {
                Text("None").tag("")
                if let id = model.albumID, !albums.contains(where: { $0.id == id }) {
                    Text(model.albumTitle ?? "Current album").tag(id)   // shown while the list loads
                }
                ForEach(albums) { album in
                    Text(album.isShared ? "\(album.title)  (\(album.photoCount), shared album)" : "\(album.title)  (\(album.photoCount))")
                        .tag(album.id)
                }
            }
            .task { await load() }
            if let id = model.albumID, albums.first(where: { $0.id == id })?.isShared == true {
                Label("Shared albums only keep reduced copies (2048 px), which are too small for the TV. Use a regular album.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if model.albumID != nil {
                Picker("When a photo is removed from the album", selection: $removal) {
                    Text("Remove it from the TV").tag("removeFromTV")
                    Text("Keep it on the TV").tag("keep")
                }
                Text("New photos in the album show up in the Library within seconds, waiting for you to pick their crop. Edits you make in Photos are picked up too. Sending is still up to you.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let last = model.lastAlbumSync {
                        Text("Last synced \(last.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isSyncingAlbum { ProgressView().controlSize(.small) }
                    Button("Sync Now") { Task { await model.syncAlbum(userInitiated: true) } }
                        .disabled(model.isSyncingAlbum)
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            albums = try await PhotosAlbumSync.albums()
            needsAccess = false
        } catch {
            needsAccess = true
        }
    }
}
