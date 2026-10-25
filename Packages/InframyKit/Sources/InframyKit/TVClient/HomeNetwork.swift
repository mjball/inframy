import Foundation

/// Whether the Mac is on the TV's network. The Frame can't be reached from anywhere else (not even another subnet),
/// so away from home Inframy shouldn't search, wake or report an error.
///
/// Home is recognised by the router's hardware address (the default gateway's MAC), learned automatically each
/// time Inframy connects to the TV. No setup, works on Wi-Fi and Ethernet, and needs no Location permission
/// (which reading the Wi-Fi name does on macOS 14+).
public enum HomeNetwork {
    /// A network Inframy has reached the TV from.
    public struct Fingerprint: Codable, Hashable, Sendable {
        public var gatewayMAC: String
        /// For people reading tv.json; not compared.
        public var gatewayIP: String?

        public init(gatewayMAC: String, gatewayIP: String? = nil) {
            self.gatewayMAC = HomeNetwork.normalizedMAC(gatewayMAC) ?? gatewayMAC.lowercased()
            self.gatewayIP = gatewayIP
        }
    }

    /// The network the Mac is on right now.
    public struct Snapshot: Sendable, Equatable {
        /// nil: no default route (offline).
        public var gatewayIP: String?
        /// nil: the router's address isn't known yet (no ARP entry).
        public var gatewayMAC: String?

        public init(gatewayIP: String?, gatewayMAC: String?) {
            self.gatewayIP = gatewayIP
            self.gatewayMAC = gatewayMAC.flatMap(HomeNetwork.normalizedMAC)
        }

        public var fingerprint: Fingerprint? {
            gatewayMAC.map { Fingerprint(gatewayMAC: $0, gatewayIP: gatewayIP) }
        }
    }

    public enum Location: Sendable, Equatable {
        case home
        case away
        /// Not enough to tell (nothing learned yet, or the router's address is missing): behave as if home.
        case unknown
    }

    public static func classify(_ snapshot: Snapshot, known: [Fingerprint]) -> Location {
        guard snapshot.gatewayIP != nil else { return .away }  // offline: the TV can't be reachable
        guard !known.isEmpty, let mac = snapshot.gatewayMAC else { return .unknown }
        return known.contains { $0.gatewayMAC == mac } ? .home : .away
    }

    /// Reads the default gateway and its MAC (`route -n get default`, then `arp -n`). Takes a few milliseconds.
    public static func current() async -> Snapshot {
        await Task.detached {
            guard let route = run("/sbin/route", ["-n", "get", "default"]), let ip = parseGateway(route) else {
                return Snapshot(gatewayIP: nil, gatewayMAC: nil)
            }
            let mac = run("/usr/sbin/arp", ["-n", ip]).flatMap { parseMAC($0, ip: ip) }
            return Snapshot(gatewayIP: ip, gatewayMAC: mac)
        }.value
    }

    // MARK: Parsing (tested against captured output)

    /// The `gateway:` line of `route -n get default`, when it's an IPv4 address.
    static func parseGateway(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "gateway" else { continue }
            let octets = parts[1].split(separator: ".")
            guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
            return parts[1]
        }
        return nil
    }

    /// `? (192.168.4.1) at 50:27:a9:4e:9e:4d on en0 ifscope [ethernet]` → `50:27:a9:4e:9e:4d`.
    static func parseMAC(_ output: String, ip: String) -> String? {
        for line in output.split(separator: "\n") where line.contains("(\(ip))") {
            let words = line.split(separator: " ")
            guard let at = words.firstIndex(of: "at"), at + 1 < words.count else { continue }
            return normalizedMAC(String(words[at + 1]))
        }
        return nil
    }

    /// Lowercase, two digits per byte (`arp` prints `0:1:2:…`). nil for `(incomplete)` and other non-MACs.
    static func normalizedMAC(_ text: String) -> String? {
        let bytes = text.split(separator: ":", omittingEmptySubsequences: false)
        guard bytes.count == 6 else { return nil }
        var out: [String] = []
        for b in bytes {
            guard (1...2).contains(b.count), let v = UInt8(b, radix: 16) else { return nil }
            out.append(String(format: "%02x", v))
        }
        return out.joined(separator: ":")
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Both tools answer from local tables; don't let a stuck one hold up connecting.
        let deadline = DispatchTime.now() + 2
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension SavedTV {
    /// Remembers the current network as one the TV is reachable from. Returns true if it was new.
    @discardableResult
    public mutating func learnHomeNetwork(_ snapshot: HomeNetwork.Snapshot) -> Bool {
        guard let fingerprint = snapshot.fingerprint else { return false }
        var known = homeNetworks ?? []
        guard !known.contains(where: { $0.gatewayMAC == fingerprint.gatewayMAC }) else { return false }
        known.append(fingerprint)
        homeNetworks = known
        return true
    }
}
