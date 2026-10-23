import InframyKit
import SwiftUI

@main
struct InframyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Inframy", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    DevSnapshot.scheduleIfRequested(model: model)
                    await model.start()
                }
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: model.tvState.isConnected ? "photo.artframe" : "photo.artframe.circle")
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Photos…") { NotificationCenter.default.post(name: .importPhotos, object: nil) }
                    .keyboardShortcut("o")
            }
            CommandMenu("TV") {
                Button("Reconnect") { Task { await model.connect() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Refresh") { Task { await model.refreshTV() } }
                    .keyboardShortcut("r")
                Button("Wake TV") { model.wake() }
                Divider()
                Button("Send Ready Photos") { let ids = model.readyToSend.map(\.id); Task { await model.requestSend(ids) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.readyToSend.isEmpty)
            }
        }
    }
}

extension Notification.Name {
    static let importPhotos = Notification.Name("InframyImportPhotos")
}
