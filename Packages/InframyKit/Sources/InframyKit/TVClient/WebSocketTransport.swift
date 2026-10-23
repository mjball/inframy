import CryptoKit
import Foundation

/// A text-frame WebSocket. Abstracted so tests can swap in a fake.
public protocol ArtTransport: Sendable {
    func send(_ text: String) async throws
    /// Next text frame. Binary frames are skipped (only API 0.97 TVs send them).
    func receive() async throws -> String
    func close()
    /// SHA-256 (hex) of the server's leaf certificate, once the TLS handshake has happened. Nil for plain ws.
    var serverCertificateFingerprint: String? { get }
}

/// `URLSessionWebSocketTask` transport. The TV's certificate is self-signed, so we trust it on first use and
/// pin its SHA-256 afterwards: pass the stored fingerprint as `pinnedFingerprint` and a mismatch fails the connection.
public final class URLSessionArtTransport: ArtTransport, @unchecked Sendable {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let trust: TrustDelegate

    public init(url: URL, pinnedFingerprint: String?) {
        trust = TrustDelegate(pinned: pinnedFingerprint)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 32 * 1024 * 1024
        task.resume()
    }

    public var serverCertificateFingerprint: String? { trust.observed }

    public func send(_ text: String) async throws {
        do { try await task.send(.string(text)) } catch { throw mapError(error) }
    }

    public func receive() async throws -> String {
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await task.receive() } catch { throw mapError(error) }
            switch message {
            case .string(let s): return s
            case .data: continue
            @unknown default: continue
            }
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func mapError(_ error: Error) -> Error {
        if trust.mismatch { return ArtError.certificateMismatch }
        return ArtError.disconnected(error.localizedDescription)
    }

    private final class TrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let pinned: String?
        private var _observed: String?
        private var _mismatch = false

        init(pinned: String?) { self.pinned = pinned?.lowercased() }

        var observed: String? { lock.withLock { _observed } }
        var mismatch: Bool { lock.withLock { _mismatch } }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust,
                  let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                  let leaf = chain.first else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let fingerprint = Self.fingerprint(of: leaf)
            let ok: Bool = lock.withLock {
                _observed = fingerprint
                _mismatch = pinned != nil && pinned != fingerprint
                return !_mismatch
            }
            if ok {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        static func fingerprint(of cert: SecCertificate) -> String {
            let der = SecCertificateCopyData(cert) as Data
            return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        }
    }
}
