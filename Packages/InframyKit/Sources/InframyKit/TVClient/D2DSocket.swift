import Foundation
import Network

/// The TV's side-channel for file transfers ("d2d socket"). After a `ready_to_use` reply, the client opens TCP to
/// the `ip`/`port` in its `conn_info` (TLS only if `secured` is true; Matt's TV omits it), then a file is framed as:
/// 4-byte big-endian header length, a JSON header, then the file bytes.
public enum D2DSocket {
    public struct Endpoint: Sendable, Equatable {
        public var host: String
        public var port: UInt16
        public var secured: Bool
        /// `key`, echoed back as `secKey` in upload headers.
        public var key: String?

        /// Reads `conn_info` from a reply. It's a JSON document in a string (sometimes nested once more).
        public init(connInfo message: ArtMessage) throws {
            guard let info = message["conn_info"]?.decodedIfString,
                  let host = info["ip"]?.stringValue,
                  let portString = info["port"]?.stringValue, let port = UInt16(portString) else {
                throw ArtError.unexpectedResponse("no usable conn_info in `\(message.event)`")
            }
            self.host = host
            self.port = port
            self.secured = info["secured"]?.stringValue == "true"
            self.key = info["key"]?.stringValue
        }

        public init(host: String, port: UInt16, secured: Bool = false, key: String? = nil) {
            self.host = host
            self.port = port
            self.secured = secured
            self.key = key
        }
    }

    public static func uploadHeader(fileLength: Int, fileType: String, key: String) -> Data {
        let header: JSON = [
            "num": 0, "total": 1, "fileLength": .number(Double(fileLength)), "fileName": "image",
            "fileType": .string(fileType), "secKey": .string(key), "version": "0.0.1",
        ]
        return Data(header.serialized().utf8)
    }

    public static func frame(header: Data, body: Data) -> Data {
        var out = Data()
        var len = UInt32(header.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(header)
        out.append(body)
        return out
    }

    /// Uploads one file.
    public static func send(_ file: Data, fileType: String, to endpoint: Endpoint, timeout: Duration) async throws {
        guard let key = endpoint.key else { throw ArtError.unexpectedResponse("conn_info has no key") }
        let conn = try await Connection.open(endpoint, timeout: timeout)
        defer { conn.close() }
        try await conn.send(frame(header: uploadHeader(fileLength: file.count, fileType: fileType, key: key), body: file))
    }

    /// Receives one file (thumbnails). Returns the header (`fileID`, `fileType`, `num`, `total`...) and bytes.
    public static func receive(from endpoint: Endpoint, timeout: Duration) async throws -> (header: JSON, data: Data) {
        let conn = try await Connection.open(endpoint, timeout: timeout)
        defer { conn.close() }
        let lenBytes = try await conn.read(exactly: 4)
        let headerLength = lenBytes.reduce(0) { ($0 << 8) | Int($1) }
        guard headerLength > 0, headerLength < 1_000_000 else {
            throw ArtError.unexpectedResponse("d2d header length \(headerLength)")
        }
        let header = try JSON.parse(try await conn.read(exactly: headerLength))
        guard let length = header["fileLength"]?.intValue, length >= 0 else {
            throw ArtError.unexpectedResponse("d2d header without fileLength")
        }
        return (header, try await conn.read(exactly: length))
    }

    /// Minimal async wrapper over NWConnection.
    final class Connection: @unchecked Sendable {
        private let nw: NWConnection
        private let queue = DispatchQueue(label: "inframy.d2d")

        private init(_ nw: NWConnection) { self.nw = nw }

        static func open(_ endpoint: Endpoint, timeout: Duration) async throws -> Connection {
            let params: NWParameters
            if endpoint.secured {
                let tls = NWProtocolTLS.Options()
                // The TV's certificate is self-signed; the channel is already authenticated by the WebSocket.
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, done in done(true) },
                                                      DispatchQueue.global())
                params = NWParameters(tls: tls)
            } else {
                params = .tcp
            }
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
                throw ArtError.unexpectedResponse("bad d2d port")
            }
            let conn = Connection(NWConnection(host: NWEndpoint.Host(endpoint.host), port: port, using: params))
            try await withTimeout(timeout, "the TV's file socket", onTimeout: { conn.close() }) {
                try await conn.start()
            }
            return conn
        }

        private func start() async throws {
            let once = Once()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                nw.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { cont.resume() }
                    case .failed(let e): once.run { cont.resume(throwing: ArtError.disconnected("d2d: \(e)")) }
                    case .cancelled: once.run { cont.resume(throwing: ArtError.disconnected("d2d cancelled")) }
                    default: break
                    }
                }
                nw.start(queue: queue)
            }
        }

        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                nw.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { err in
                    if let err { cont.resume(throwing: ArtError.disconnected("d2d send: \(err)")) } else { cont.resume() }
                })
            }
        }

        func read(exactly count: Int) async throws -> Data {
            var buffer = Data()
            while buffer.count < count {
                let chunk: Data = try await withCheckedThrowingContinuation { cont in
                    nw.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { data, _, isComplete, err in
                        if let err { cont.resume(throwing: ArtError.disconnected("d2d receive: \(err)")); return }
                        if let data, !data.isEmpty { cont.resume(returning: data); return }
                        cont.resume(throwing: ArtError.disconnected(isComplete ? "d2d socket closed early" : "d2d: no data"))
                    }
                }
                buffer.append(chunk)
            }
            return buffer
        }

        func close() { nw.cancel() }
    }
}

/// Runs a closure at most once (NWConnection can report several terminal states).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first: Bool = lock.withLock { defer { done = true }; return !done }
        if first { body() }
    }
}
