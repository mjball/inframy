import Foundation
import Network

/// `GET http://<host>:8001/api/v2/`: the TV's REST device info. No pairing needed.
public struct TVDeviceInfo: Sendable, Equatable {
    /// Stable id (`uuid:…`). Use this, not the IP, to recognise the TV.
    public var id: String
    public var name: String
    public var model: String?
    public var host: String
    public var wifiMAC: String?
    public var isFrame: Bool
    public var powerState: String?
    public var networkType: String?

    public init?(json: JSON, host: String) {
        let device = json["device"] ?? .object([:])
        guard let id = device["id"]?.stringValue ?? json["id"]?.stringValue else { return nil }
        self.id = id
        self.name = device["name"]?.stringValue ?? json["name"]?.stringValue ?? "Samsung TV"
        self.model = device["modelName"]?.stringValue
        self.host = device["ip"]?.nonEmptyString ?? host
        self.wifiMAC = device["wifiMac"]?.nonEmptyString
        self.isFrame = device["FrameTVSupport"]?.stringValue?.lowercased() == "true"
        self.powerState = device["PowerState"]?.stringValue
        self.networkType = device["networkType"]?.stringValue
    }

    public static func fetch(host: String, timeout: TimeInterval = 4) async throws -> TVDeviceInfo {
        guard let url = URL(string: "http://\(host):8001/api/v2/") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let info = TVDeviceInfo(json: try JSON.parse(data), host: host) else {
            throw ArtError.unexpectedResponse("REST device info without an id")
        }
        return info
    }
}

/// Finds Frame TVs on the local network.
///
/// Bonjour (`_samsungmsf._tcp`) is the primary method: the TXT record's `se` field holds the REST URL.
/// Matt's TV stops answering SSDP once its gateway points at itself (no-internet setup), but keeps
/// advertising over Bonjour. Each candidate is confirmed via REST `FrameTVSupport`.
public enum TVDiscovery {
    public static let bonjourType = "_samsungmsf._tcp"

    public static func findFrames(timeout: Duration = .seconds(3)) async -> [TVDeviceInfo] {
        let hosts = await bonjourHosts(timeout: timeout)
        var frames: [TVDeviceInfo] = []
        await withTaskGroup(of: TVDeviceInfo?.self) { group in
            for host in hosts { group.addTask { try? await TVDeviceInfo.fetch(host: host) } }
            for await info in group { if let info, info.isFrame { frames.append(info) } }
        }
        return frames.sorted { $0.name < $1.name }
    }

    /// Browses for `timeout` and returns the hosts from each service's TXT `se=http://<host>:8001/api/v2/`.
    public static func bonjourHosts(timeout: Duration) async -> Set<String> {
        let collector = HostCollector()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: bonjourType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                if case .bonjour(let txt) = result.metadata, let se = txt["se"], let host = URL(string: se)?.host {
                    collector.add(host)
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "inframy.discovery"))
        try? await Task.sleep(for: timeout)
        browser.cancel()
        return collector.hosts
    }

    private final class HostCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _hosts = Set<String>()
        func add(_ host: String) { lock.withLock { _ = _hosts.insert(host) } }
        var hosts: Set<String> { lock.withLock { _hosts } }
    }
}

/// Wake-on-LAN ("Power On with Mobile" on the TV). Needs the TV's Wi-Fi MAC from REST info.
public enum WakeOnLAN {
    public static func magicPacket(mac: String) throws -> Data {
        let bytes = mac.split(whereSeparator: { $0 == ":" || $0 == "-" }).compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { throw ArtError.unexpectedResponse("bad MAC address \(mac)") }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }

    /// Broadcasts the magic packet to 255.255.255.255 on ports 9 and 7.
    public static func wake(mac: String) throws {
        let packet = try magicPacket(mac: mac)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        for port in [UInt16(9), 7] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_BROADCAST
            let sent = packet.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }
}
