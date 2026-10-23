import Foundation

/// Wire format of the TV's art-app channel. See docs/PROTOCOL.md.
public enum ArtProtocol {
    public static let channel = "com.samsung.art-app"
    public static let clientName = "Inframy"
    public static let personalCategory = "MY-C0002"

    /// `wss://<host>:8002/api/v2/channels/com.samsung.art-app?name=<base64 name>[&token=<token>]`
    public static func channelURL(host: String, port: Int = 8002, secure: Bool = true, token: String? = nil) -> URL {
        func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        var c = URLComponents()
        c.scheme = secure ? "wss" : "ws"
        c.host = host
        c.port = port
        c.path = "/api/v2/channels/\(channel)"
        var query = "name=" + escape(Data(clientName.utf8).base64EncodedString())  // name=SW5mcmFteQ%3D%3D
        if let token { query += "&token=" + escape(token) }
        c.percentEncodedQuery = query
        return c.url!
    }

    /// Builds the text frame for one art request. `data` is a JSON document encoded as a string, and carries
    /// both `id` (older API) and `request_id` (newer API) with the same value.
    public static func encodeRequest(_ request: String, id: String, params: [String: JSON] = [:]) -> String {
        var inner = params
        inner["request"] = .string(request)
        inner["id"] = .string(id)
        inner["request_id"] = .string(id)
        let envelope: JSON = [
            "method": "ms.channel.emit",
            "params": [
                "event": "art_app_request",
                "to": "host",
                "data": .string(JSON.object(inner).serialized()),
            ],
        ]
        return envelope.serialized()
    }

    /// Everything the TV can send on the channel, classified.
    public enum Incoming: Sendable, Equatable {
        /// `ms.channel.connect`. `token` is present only on TVs that issue one (Matt's doesn't).
        case connected(token: String?)
        case ready
        /// `ms.channel.unauthorized` or `ms.channel.timeOut`: the user declined, or a stale token was sent.
        case refused(event: String)
        /// A `d2d_service_message` whose `data` decoded to an object.
        case message(ArtMessage)
        case other(event: String)
    }

    public static func decode(_ text: String) throws -> Incoming {
        let frame = try JSON.parse(text)
        let event = frame["event"]?.stringValue ?? ""
        switch event {
        case "ms.channel.connect":
            return .connected(token: frame["data"]?["token"]?.stringValue)
        case "ms.channel.ready":
            return .ready
        case "ms.channel.unauthorized", "ms.channel.timeOut":
            return .refused(event: event)
        case "d2d_service_message":
            guard let payload = frame["data"]?.decodedIfString, payload.objectValue != nil else {
                return .other(event: event)
            }
            return .message(ArtMessage(payload: payload))
        default:
            return .other(event: event)
        }
    }
}

/// One decoded art-app message (the JSON inside `d2d_service_message.data`).
public struct ArtMessage: Sendable, Equatable {
    public let payload: JSON

    public init(payload: JSON) { self.payload = payload }

    /// Correlation id. Broadcasts (e.g. the second copy of `image_added`) have none.
    public var id: String? { payload["request_id"]?.stringValue ?? payload["id"]?.stringValue }
    /// The sub-event, e.g. `api_version`, `image_added`, `error`.
    public var event: String { payload["event"]?.stringValue ?? "" }

    public var error: ArtError? {
        guard event == "error" else { return nil }
        let request = payload["request_data"]?.decodedIfString?["request"]?.stringValue
        return ArtError.tv(code: payload["error_code"]?.stringValue ?? "?", request: request)
    }

    public subscript(key: String) -> JSON? { payload[key] }
}

public enum ArtError: Error, Equatable, CustomStringConvertible {
    /// The TV answered with `event: error`. `-9` = request not supported on this TV; `-7` = bad parameter.
    case tv(code: String, request: String?)
    case refused(String)
    case timedOut(String)
    case disconnected(String)
    case unexpectedResponse(String)
    case certificateMismatch

    public var isUnsupportedRequest: Bool {
        if case .tv(code: "-9", _) = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .tv(let code, let request):
            let hint = code == "-9" ? " (not supported on this TV)" : code == "-7" ? " (invalid parameter)" : ""
            return "TV rejected `\(request ?? "request")` with error \(code)\(hint)"
        case .refused(let event): return "TV refused the connection (\(event)). Allow it on the TV and try again."
        case .timedOut(let what): return "Timed out waiting for \(what)"
        case .disconnected(let why): return "Disconnected from the TV: \(why)"
        case .unexpectedResponse(let what): return "Unexpected response from the TV: \(what)"
        case .certificateMismatch:
            return "The TV's TLS certificate changed since pairing. If the TV was reset or replaced, run `pair` again."
        }
    }
}
