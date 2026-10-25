import Foundation

/// One persistent connection to a TV's art channel. Opening a connection per request can trigger the TV's
/// pairing prompt, so keep one of these per TV and reuse it. It reconnects lazily after a drop.
public actor TVConnection {
    public struct Options: Sendable {
        public var host: String
        public var port: Int
        public var secure: Bool
        public var token: String?
        /// SHA-256 of the TV's certificate from an earlier connection (trust on first use when nil).
        public var pinnedCertificate: String?
        public var timeout: Duration

        public init(host: String, port: Int = 8002, secure: Bool = true, token: String? = nil,
                    pinnedCertificate: String? = nil, timeout: Duration = .seconds(20)) {
            self.host = host
            self.port = port
            self.secure = secure
            self.token = token
            self.pinnedCertificate = pinnedCertificate
            self.timeout = timeout
        }
    }

    public typealias TransportFactory = @Sendable (URL, _ pinnedCertificate: String?) -> any ArtTransport

    public nonisolated let options: Options
    private let makeTransport: TransportFactory
    private var transport: (any ArtTransport)?
    private var readerTask: Task<Void, Never>?
    /// The connection attempt in progress, shared by concurrent callers.
    private var connecting: Task<Void, Error>?
    /// Bumped on every close/drop, so a stale reader or attempt can't tear down a newer connection.
    private var generation = 0
    private var waiters: [UUID: Waiter] = [:]
    private var broadcastContinuations: [UUID: AsyncStream<ArtMessage>.Continuation] = [:]

    /// Token the TV issued in `ms.channel.connect`, if any. Store it and pass it as `Options.token` next time.
    public private(set) var issuedToken: String?
    /// Fingerprint of the TV's certificate seen on the last connection. Store it to pin later connections.
    public private(set) var certificateFingerprint: String?

    public init(options: Options, transport: TransportFactory? = nil) {
        self.options = options
        self.makeTransport = transport ?? { url, pin in URLSessionArtTransport(url: url, pinnedFingerprint: pin) }
    }

    public var isConnected: Bool { transport != nil }

    // MARK: Connecting

    /// Connects if needed. Concurrent callers share one attempt, so there's never more than one connection.
    public func connect() async throws {
        if transport != nil { return }
        if let connecting { return try await connecting.value }
        let attempt = Task { try await self.open() }
        connecting = attempt
        defer { if connecting == attempt { connecting = nil } }
        try await attempt.value
    }

    private func open() async throws {
        let startedIn = generation
        let url = ArtProtocol.channelURL(host: options.host, port: options.port, secure: options.secure,
                                         token: options.token ?? issuedToken)
        let t = makeTransport(url, options.pinnedCertificate)
        do {
            let token = try await withTimeout(options.timeout, "the TV to accept the connection",
                                              onTimeout: { t.close() }) {
                try await Self.handshake(t)
            }
            if let token { issuedToken = token }
        } catch {
            t.close()
            throw error
        }
        guard generation == startedIn else {
            t.close()
            throw ArtError.disconnected("closed while connecting")
        }
        certificateFingerprint = t.serverCertificateFingerprint
        transport = t
        let current = generation
        readerTask = Task { [weak self] in await self?.readLoop(t, generation: current) }
    }

    /// Reads until `ms.channel.ready`. Returns the token from `ms.channel.connect`, if the TV sent one.
    private static func handshake(_ t: any ArtTransport) async throws -> String? {
        var token: String?
        while true {
            switch try ArtProtocol.decode(try await t.receive()) {
            case .connected(let tok): token = tok ?? token
            case .ready: return token
            case .refused(let event): throw ArtError.refused(event)
            case .message, .other: continue
            }
        }
    }

    public func close() {
        generation += 1
        connecting = nil
        readerTask?.cancel()
        readerTask = nil
        transport?.close()
        transport = nil
        failAll(ArtError.disconnected("closed"))
    }

    // MARK: Requests

    /// Sends `request` and returns the first reply carrying its id (or, with `until`, the first such reply with
    /// that sub-event). A reply with `event: error` throws `ArtError.tv`.
    @discardableResult
    public func request(_ request: String, params: [String: JSON] = [:], until event: String? = nil,
                        id: String = UUID().uuidString.lowercased(), timeout: Duration? = nil) async throws -> ArtMessage {
        try await connect()
        let waiter = expect(id: id) { msg in event == nil || msg.event == event }
        try await send(request, id: id, params: params)
        return try await wait(for: waiter, timeout: timeout, what: "`\(request)`")
    }

    /// Sends a request without waiting. Pair with `expect` + `wait` for multi-step exchanges (uploads).
    public func send(_ request: String, id: String, params: [String: JSON] = [:]) async throws {
        try await connect()
        guard let transport else { throw ArtError.disconnected("not connected") }
        do {
            try await transport.send(ArtProtocol.encodeRequest(request, id: id, params: params))
        } catch {
            dropConnection(error)
            throw error
        }
    }

    /// Registers interest in a future message before triggering it, so a fast reply isn't missed.
    /// Messages with `id` are matched by id; errors with that id fail the wait. `includeBroadcasts` also
    /// matches messages without an id (e.g. the broadcast copy of `image_added`).
    public func expect(id: String?, includeBroadcasts: Bool = false,
                       where match: @escaping @Sendable (ArtMessage) -> Bool) -> UUID {
        let key = UUID()
        waiters[key] = Waiter(requestID: id, includeBroadcasts: includeBroadcasts, match: match)
        return key
    }

    public func wait(for key: UUID, timeout: Duration? = nil, what: String) async throws -> ArtMessage {
        guard let waiter = waiters[key] else { throw ArtError.unexpectedResponse("unknown waiter") }
        if let result = waiter.result {
            waiters[key] = nil
            return try result.get()
        }
        let limit = timeout ?? options.timeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.finish(key, .failure(ArtError.timedOut(what)))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            if waiters[key] == nil {
                cont.resume(throwing: ArtError.disconnected("wait cancelled"))
            } else {
                waiters[key]?.continuation = cont
            }
        }
    }

    /// Drops a waiter registered with `expect` that won't be awaited (e.g. the exchange failed early).
    public func discard(_ key: UUID) {
        if let cont = waiters.removeValue(forKey: key)?.continuation {
            cont.resume(throwing: ArtError.disconnected("wait discarded"))
        }
    }

    /// Messages that no waiter claimed (broadcasts like `image_deleted`, `go_to_standby`).
    public func broadcasts() -> AsyncStream<ArtMessage> {
        let key = UUID()
        let (stream, cont) = AsyncStream<ArtMessage>.makeStream()
        broadcastContinuations[key] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.removeBroadcast(key) } }
        return stream
    }

    private func removeBroadcast(_ key: UUID) { broadcastContinuations[key] = nil }

    // MARK: Reading

    private func readLoop(_ t: any ArtTransport, generation reader: Int) async {
        while !Task.isCancelled {
            let text: String
            do {
                text = try await t.receive()
            } catch {
                if Task.isCancelled { return }
                // Only the current connection's reader may drop it.
                if reader == generation { dropConnection(error) } else { t.close() }
                return
            }
            // A frame we can't parse isn't worth dropping the connection over.
            if case .message(let msg)? = try? ArtProtocol.decode(text) { route(msg) }
        }
    }

    private func route(_ msg: ArtMessage) {
        // An error ends every wait on that request (e.g. an upload waits for both `ready_to_use` and `image_added`).
        if let error = msg.error, let id = msg.id {
            let keys = waiters.filter { $0.value.result == nil && $0.value.requestID == id }.map(\.key)
            if !keys.isEmpty {
                keys.forEach { finish($0, .failure(error)) }
                return
            }
        }
        for (key, w) in waiters where w.result == nil {
            let idMatches = w.requestID != nil && msg.id == w.requestID
            if (idMatches || (w.includeBroadcasts && msg.id == nil)) && w.match(msg) {
                finish(key, .success(msg))
                return
            }
        }
        for cont in broadcastContinuations.values { cont.yield(msg) }
    }

    private func finish(_ key: UUID, _ result: Result<ArtMessage, Error>) {
        guard var w = waiters[key], w.result == nil else { return }
        if let cont = w.continuation {
            waiters[key] = nil
            cont.resume(with: result)
        } else {
            w.result = result
            waiters[key] = w
        }
    }

    private func dropConnection(_ error: Error) {
        generation += 1
        transport?.close()
        transport = nil
        readerTask = nil
        failAll(error as? ArtError ?? ArtError.disconnected(error.localizedDescription))
    }

    private func failAll(_ error: Error) {
        for key in Array(waiters.keys) { finish(key, .failure(error)) }
    }

    private struct Waiter {
        let requestID: String?
        let includeBroadcasts: Bool
        let match: @Sendable (ArtMessage) -> Bool
        var continuation: CheckedContinuation<ArtMessage, Error>?
        var result: Result<ArtMessage, Error>?
    }
}

/// Runs `operation`, failing with `ArtError.timedOut` if it takes longer than `limit`.
/// `onTimeout` should unblock the operation (e.g. close its socket): the group can't return until it finishes.
func withTimeout<T: Sendable>(_ limit: Duration, _ what: String, onTimeout: @escaping @Sendable () -> Void = {},
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            onTimeout()
            throw ArtError.timedOut(what)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
