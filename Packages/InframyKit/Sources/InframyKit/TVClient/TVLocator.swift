import Foundation

/// Finds the TV to talk to: the paired one (recognised by id, re-discovered if its IP changed), else the only
/// Frame on the network.
public enum TVLocator {
    public enum Failure: Error, CustomStringConvertible {
        case noTV
        case several([TVDeviceInfo])
        case pairedTVUnreachable(SavedTV)

        public var description: String {
            switch self {
            case .noTV: return "No Frame TV found on the network. Is it on?"
            case .several(let frames):
                return "Found several Frames: \(frames.map { "\($0.name) (\($0.host))" }.joined(separator: ", "))."
            case .pairedTVUnreachable(let tv):
                return "Can't reach \(tv.name). Is it on and on the same network?"
            }
        }
    }

    /// `note` reports progress (e.g. "searching the network").
    public static func resolve(host: String? = nil, savedURL: URL = SavedTV.defaultURL,
                               note: @Sendable (String) -> Void = { _ in }) async throws -> (info: TVDeviceInfo, saved: SavedTV?) {
        if let host {
            return (try await TVDeviceInfo.fetch(host: host), SavedTV.load(from: savedURL))
        }
        if var saved = SavedTV.load(from: savedURL) {
            if let info = try? await TVDeviceInfo.fetch(host: saved.host), info.id == saved.id {
                return (info, saved)
            }
            note("\(saved.name) isn't answering at \(saved.host); searching the network…")
            if let info = await TVDiscovery.findFrames().first(where: { $0.id == saved.id }) {
                saved.host = info.host
                try? saved.save(to: savedURL)
                note("Found it at \(info.host).")
                return (info, saved)
            }
            throw Failure.pairedTVUnreachable(saved)
        }
        let frames = await TVDiscovery.findFrames()
        switch frames.count {
        case 0: throw Failure.noTV
        case 1: return (frames[0], nil)
        default: throw Failure.several(frames)
        }
    }

    /// A connection to `info`, pinned to the saved certificate when it's the paired TV.
    public static func connection(to info: TVDeviceInfo, saved: SavedTV?, timeout: Duration = .seconds(20)) -> TVConnection {
        let same = saved?.id == info.id
        return TVConnection(options: .init(host: info.host, token: same ? saved?.token : nil,
                                           pinnedCertificate: same ? saved?.certificateFingerprint : nil,
                                           timeout: timeout))
    }

    /// Remembers the TV after a successful connection (trust on first use for its certificate).
    public static func remember(_ info: TVDeviceInfo, connection: TVConnection, savedURL: URL = SavedTV.defaultURL) async throws {
        var saved = SavedTV.load(from: savedURL).flatMap { $0.id == info.id ? $0 : nil } ?? SavedTV(info: info)
        saved.host = info.host
        saved.name = info.name
        saved.model = info.model
        saved.wifiMAC = info.wifiMAC ?? saved.wifiMAC
        if saved.certificateFingerprint == nil { saved.certificateFingerprint = await connection.certificateFingerprint }
        try saved.save(to: savedURL)
        if let token = await connection.issuedToken { TokenStore.write(token, account: info.id) }
    }
}
