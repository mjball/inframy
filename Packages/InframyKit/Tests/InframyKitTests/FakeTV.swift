import Foundation
import Network
@testable import InframyKit

/// Raw frames captured from Matt's TV (see docs/PROTOCOL.md).
enum Fixture {
    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The captured frame with its request id replaced, so it answers a new request.
    static func reply(_ name: String, id: String) throws -> String {
        let text = try self.text(name)
        guard let msg = try messageInFrame(text), let old = msg.id else { return text }
        return text.replacingOccurrences(of: old, with: id)
    }

    static func message(_ name: String) throws -> ArtMessage {
        guard let msg = try messageInFrame(try text(name)) else { throw CocoaError(.coderInvalidValue) }
        return msg
    }

    private static func messageInFrame(_ text: String) throws -> ArtMessage? {
        if case .message(let m) = try ArtProtocol.decode(text) { return m }
        return nil
    }
}

/// Builds TV-shaped frames for cases we didn't capture verbatim.
enum Frame {
    static func d2d(_ payload: JSON) -> String {
        JSON.object(["event": "d2d_service_message", "from": "fake-host", "data": .string(payload.serialized())]).serialized()
    }

    static func error(id: String, request: String, code: String) -> String {
        d2d(["id": .string(id), "event": "error", "error_code": .string(code),
             "request_data": .string(JSON.object(["request": .string(request), "id": .string(id)]).serialized())])
    }

    /// `ready_to_use` with `conn_info` nested like the real TV's (a string containing `contentInfo`, another string).
    static func readyToUse(id: String, port: UInt16, key: String = "k3y") -> String {
        let contentInfo = JSON.object(["d2d_mode": "socket", "id": .string(id)]).serialized()
        let connInfo = JSON.object(["contentInfo": .string(contentInfo), "event": "get_d2d_connection",
                                    "ip": "127.0.0.1", "port": .string(String(port)), "key": .string(key),
                                    "stat": "ok", "mode": "socket"]).serialized()
        return d2d(["id": .string(id), "event": "ready_to_use", "conn_info": .string(connInfo)])
    }
}

/// A fake art channel: plain WebSocket on 127.0.0.1. Sends `ms.channel.connect` + `ready` on connect (captured
/// frames), then hands each request to `handler`, which returns frames to send back.
final class FakeTV: @unchecked Sendable {
    struct Request: Sendable {
        let name: String
        let id: String
        let params: JSON
    }

    typealias Handler = @Sendable (Request, FakeTV) throws -> [String]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-tv")
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _connectionCount = 0
    private var connections: [NWConnection] = []
    private let handler: Handler
    private(set) var port: UInt16 = 0

    var requests: [Request] { lock.withLock { _requests } }
    var connectionCount: Int { lock.withLock { _connectionCount } }

    init(handler: @escaping Handler) async throws {
        self.handler = handler
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        port = try await Self.start(listener, on: queue)
    }

    static func start(_ listener: NWListener, on queue: DispatchQueue) async throws -> UInt16 {
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let e): once.run { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func options(timeout: Duration = .seconds(5)) -> TVConnection.Options {
        .init(host: "127.0.0.1", port: Int(port), secure: false, timeout: timeout)
    }

    func client(timeout: Duration = .seconds(5)) -> ArtClient {
        ArtClient(connection: TVConnection(options: options(timeout: timeout)))
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }

    /// Sends a frame to every connected client (for broadcasts).
    func broadcast(_ text: String) {
        lock.withLock { connections }.forEach { send(text, on: $0) }
    }

    private func accept(_ conn: NWConnection) {
        lock.withLock {
            _connectionCount += 1
            connections.append(conn)
        }
        conn.start(queue: queue)
        if let connect = try? Fixture.text("connect"), let ready = try? Fixture.text("ready") {
            send(connect, on: conn)
            send(ready, on: conn)
        }
        receive(on: conn)
    }

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            self.handle(String(decoding: data, as: UTF8.self), on: conn)
            self.receive(on: conn)
        }
    }

    private func handle(_ text: String, on conn: NWConnection) {
        guard let envelope = try? JSON.parse(text),
              let inner = envelope["params"]?["data"]?.decodedIfString,
              let name = inner["request"]?.stringValue, let id = inner["id"]?.stringValue else { return }
        let request = Request(name: name, id: id, params: inner)
        lock.withLock { _requests.append(request) }
        let replies = (try? handler(request, self)) ?? []
        for reply in replies { send(reply, on: conn) }
    }

    private func send(_ text: String, on conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        conn.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .idempotent)
    }
}

/// A fake d2d file socket on 127.0.0.1: either receives one upload or sends one file.
final class FakeD2D: @unchecked Sendable {
    enum Mode: Sendable {
        case receive
        case send(header: JSON, body: Data)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-d2d")
    private let lock = NSLock()
    private var _received = Data()
    private let mode: Mode
    private let onUploadComplete: (@Sendable (Data) -> Void)?
    private(set) var port: UInt16 = 0

    var received: Data { lock.withLock { _received } }

    init(mode: Mode, onUploadComplete: (@Sendable (Data) -> Void)? = nil) async throws {
        self.mode = mode
        self.onUploadComplete = onUploadComplete
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        port = try await FakeTV.start(listener, on: queue)
    }

    func stop() { listener.cancel() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        switch mode {
        case .receive:
            read(conn)
        case .send(let header, let body):
            let framed = D2DSocket.frame(header: Data(header.serialized().utf8), body: body)
            conn.send(content: framed, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    private func read(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.lock.withLock { self._received.append(data) } }
            if isComplete || error != nil {
                conn.cancel()
                self.onUploadComplete?(self.received)
            } else {
                self.read(conn)
            }
        }
    }
}
