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
    static let wakeOnOpen = "wakeOnOpen"

    static func register() {
        UserDefaults.standard.register(defaults: [
            shuffleMinutes: 15, keepShuffleOn: true, wakeOnOpen: true, albumRemoval: "removeFromTV",
        ])
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.keepShuffleOn) private var keepShuffleOn = true
    @AppStorage(Prefs.wakeOnOpen) private var wakeOnOpen = true
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Photos album") {
                RemovalSetting()
            }
            Section("TV") {
                Toggle("Keep the slideshow on", isOn: $keepShuffleOn)
                Text("Whenever the TV is awake, Inframy turns My Photos shuffle back on if it has stopped (2020 Frames sometimes do), at the interval it last had. Choose the interval from the shuffle menu in On the TV. The TV only counts time with the screen on (not while the motion sensor has it asleep).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Wake the TV when I open Inframy", isOn: $wakeOnOpen)
                Text("At home, opening Inframy or switching to it wakes the Frame if it's asleep (at most every 3 minutes). Away from home Inframy waits quietly.")
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

/// What happens on the TV when a photo is taken out of the album. (The album itself is chosen in the toolbar.)
struct RemovalSetting: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.albumRemoval) private var removal = "removeFromTV"

    var body: some View {
        LabeledContent("Album", value: model.albumTitle ?? "None chosen")
        Picker("When a photo is removed from the album", selection: $removal) {
            Text("Remove it from the TV").tag("removeFromTV")
            Text("Keep it on the TV").tag("keep")
        }
        Text("Choose or switch the album from the album menu in the main window's toolbar.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
