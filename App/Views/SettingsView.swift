import InframyKit
import SwiftUI

enum Prefs {
    static let albumSyncEnabled = "albumSyncEnabled"
    static let albumName = "albumName"
    static let shuffleMinutes = "shuffleMinutes"
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.albumSyncEnabled) private var albumSync = false
    @AppStorage(Prefs.albumName) private var albumName = PhotosAlbumSync.defaultAlbumName
    @AppStorage(Prefs.shuffleMinutes) private var shuffleMinutes = 15

    var body: some View {
        Form {
            Section("Photos") {
                Toggle("Import new photos from a Photos album", isOn: $albumSync)
                TextField("Album name", text: $albumName)
                    .disabled(!albumSync)
                Text("New photos in the album appear in the Library waiting for you to pick their crop. Nothing is sent automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Sync Now") { Task { await model.syncAlbum(userInitiated: true) } }
                    .disabled(!albumSync || model.isSyncingAlbum)
            }
            Section("TV") {
                Picker("Shuffle interval when Inframy turns shuffle on", selection: $shuffleMinutes) {
                    ForEach(ShuffleControl.intervals, id: \.0) { Text($0.1).tag($0.0) }
                }
                if let tv = SavedTV.load() {
                    LabeledContent("Paired TV", value: "\(tv.name.replacingOccurrences(of: "[TV] ", with: "")) · \(tv.host)")
                    LabeledContent("Model", value: tv.model ?? "?")
                }
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
