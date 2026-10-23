import InframyKit
import ServiceManagement
import SwiftUI

enum Prefs {
    static let albumSyncEnabled = "albumSyncEnabled"
    static let albumName = "albumName"
    static let shuffleMinutes = "shuffleMinutes"
    static let keepShuffleOn = "keepShuffleOn"
    static let rotationEnabled = "rotationEnabled"
    static let poolSize = "poolSize"
    static let rotationHours = "rotationHours"
    static let swapPercent = "swapPercent"
    static let wakeForRotation = "wakeForRotation"
    static let lastRotation = "lastRotation"

    static func register() {
        UserDefaults.standard.register(defaults: [
            albumName: PhotosAlbumSync.defaultAlbumName, shuffleMinutes: 15, keepShuffleOn: true,
            rotationEnabled: false, poolSize: 40, rotationHours: 24, swapPercent: 20, wakeForRotation: false,
        ])
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.albumSyncEnabled) private var albumSync = false
    @AppStorage(Prefs.albumName) private var albumName = PhotosAlbumSync.defaultAlbumName
    @AppStorage(Prefs.shuffleMinutes) private var shuffleMinutes = 15
    @AppStorage(Prefs.keepShuffleOn) private var keepShuffleOn = true
    @AppStorage(Prefs.rotationEnabled) private var rotationEnabled = false
    @AppStorage(Prefs.poolSize) private var poolSize = 40
    @AppStorage(Prefs.rotationHours) private var rotationHours = 24
    @AppStorage(Prefs.swapPercent) private var swapPercent = 20
    @AppStorage(Prefs.wakeForRotation) private var wakeForRotation = false
    @State private var openAtLogin = LoginItem.isEnabled

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
                Toggle("Keep the slideshow on", isOn: $keepShuffleOn)
                Text("While Inframy is running, it turns My Photos shuffle back on if the TV stops it (2020 Frames sometimes do).")
                    .font(.caption).foregroundStyle(.secondary)
                if let tv = SavedTV.load() {
                    LabeledContent("Paired TV", value: "\(tv.name.replacingOccurrences(of: "[TV] ", with: "")) · \(tv.host)")
                    LabeledContent("Model", value: tv.model ?? "?")
                }
            }
            Section("Rotation") {
                Toggle("Rotate photos on the TV", isOn: $rotationEnabled)
                Group {
                    Stepper("Keep \(poolSize) photos on the TV", value: $poolSize, in: 5...500, step: 5)
                    Picker("Rotate", selection: $rotationHours) {
                        Text("Every 6 hours").tag(6)
                        Text("Every 12 hours").tag(12)
                        Text("Daily").tag(24)
                        Text("Every 3 days").tag(72)
                        Text("Weekly").tag(168)
                    }
                    Stepper("Swap \(swapPercent)% each time", value: $swapPercent, in: 5...100, step: 5)
                    Toggle("Wake the TV to rotate", isOn: $wakeForRotation)
                    Text("Your library can be bigger than the TV holds. Inframy keeps this many on the TV and swaps in the photos that have been off it longest. Pinned photos stay. Only photos Inframy sent (or you linked) are ever taken down.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let last = model.lastRotation {
                        LabeledContent("Last rotation", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Rotate Now") { Task { await model.rotate(userInitiated: true) } }
                        .disabled(model.isRotating)
                }
                .disabled(!rotationEnabled)
            }
            Section("General") {
                Toggle("Open Inframy at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in openAtLogin = LoginItem.set(on) }
                Text("Keeps the menu bar item running so the slideshow and rotation are looked after.")
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
