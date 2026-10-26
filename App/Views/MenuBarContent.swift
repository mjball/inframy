import InframyKit
import SwiftUI

/// The menu bar item: TV status and the background chores, available even with the window closed.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status)
        if let s = model.slideshow, let m = s.intervalMinutes {
            Text("Shuffling \(s.contentIDs.count) photos, every \(m) min of screen-on time")
        } else if model.tvState.isConnected {
            Text("Slideshow off")
        }
        Divider()
        Button("Open Inframy") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Button("Send Ready Photos (\(model.readyToSend.count))") { let ids = model.readyToSend.map(\.id); model.send(ids) }
            .disabled(model.readyToSend.isEmpty)
        Button("Turn Shuffle On") { Task { await model.setShuffle(on: true) } }
            .disabled(!model.tvState.isConnected || model.slideshow?.isOn == true)
        Divider()
        Button("Connect to TV") { Task { await model.connectNow() } }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Inframy") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var status: String {
        switch model.tvState {
        case .connected: return "\(model.tvName): connected"
        case .searching: return "Connecting to the TV…"
        case .unavailable: return "TV not reachable"
        case .away: return "Away from home"
        }
    }
}
