import InframyKit
import SwiftUI

@main
struct InframyApp: App {
    var body: some Scene {
        WindowGroup("Inframy") {
            ContentView()
                .frame(minWidth: 640, minHeight: 400)
        }
    }
}

/// Phase 1 placeholder: shows which TV is paired and whether it's reachable. The real UI (import, crop editor,
/// "On the TV" grid) is Phase 2.
struct ContentView: View {
    @State private var status = "Looking for your Frame…"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.artframe")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Inframy").font(.largeTitle)
            Text(status).foregroundStyle(.secondary)
        }
        .padding(40)
        .task { status = await Self.checkTV() }
    }

    static func checkTV() async -> String {
        if let saved = SavedTV.load() {
            if let info = try? await TVDeviceInfo.fetch(host: saved.host), info.id == saved.id {
                return "\(saved.name) is reachable at \(info.host)."
            }
            return "\(saved.name) isn't reachable right now."
        }
        let frames = await TVDiscovery.findFrames()
        return frames.first.map { "Found \($0.name) at \($0.host). Pair it with `inframy-cli pair`." }
            ?? "No Frame TV found on this network."
    }
}
