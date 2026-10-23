import Foundation
import Security

/// The TV Inframy is paired with, remembered by its stable device id. The IP is only a hint: on connection
/// failure, re-discover by id and update it. Stored at ~/Library/Application Support/Inframy/tv.json.
/// A pairing token (if the TV ever issues one) goes in the Keychain, never in this file.
public struct SavedTV: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var model: String?
    public var host: String
    public var wifiMAC: String?
    /// SHA-256 of the TV's TLS certificate, pinned after the first connection.
    public var certificateFingerprint: String?

    public init(info: TVDeviceInfo, certificateFingerprint: String? = nil) {
        id = info.id
        name = info.name
        model = info.model
        host = info.host
        wifiMAC = info.wifiMAC
        self.certificateFingerprint = certificateFingerprint
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inframy/tv.json")
    }

    public static func load(from url: URL = defaultURL) -> SavedTV? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedTV.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public var token: String? { TokenStore.read(account: id) }
}

/// Keychain storage for pairing tokens (generic password, service "Inframy", account = TV id).
public enum TokenStore {
    static let service = "Inframy"

    public static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func write(_ token: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
