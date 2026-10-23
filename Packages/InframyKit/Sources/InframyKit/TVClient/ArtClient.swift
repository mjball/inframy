import Foundation

/// Typed art-mode API over one `TVConnection`. Command names and quirks follow docs/PROTOCOL.md
/// (verified on a 2020 Frame, Art API 2.03).
public actor ArtClient {
    public let connection: TVConnection
    /// Which slideshow command family works: 2020 firmware uses `*_auto_rotation_status`, 2022+ `*_slideshow_status`.
    private var slideshowCommand: String?

    public init(connection: TVConnection) { self.connection = connection }

    public init(host: String, pinnedCertificate: String? = nil, token: String? = nil) {
        connection = TVConnection(options: .init(host: host, token: token, pinnedCertificate: pinnedCertificate))
    }

    // MARK: Info

    /// Newer TVs answer `api_version`; older ones (Matt's 2.03) reject it with -9 and answer `get_api_version`.
    public func apiVersion() async throws -> String {
        let reply: ArtMessage
        do {
            reply = try await connection.request("api_version")
        } catch let e as ArtError where e.isUnsupportedRequest {
            reply = try await connection.request("get_api_version")
        }
        guard let version = reply["version"]?.stringValue else {
            throw ArtError.unexpectedResponse("no version in `\(reply.event)`")
        }
        return version
    }

    public func deviceInfo() async throws -> JSON {
        try await connection.request("get_device_info").payload
    }

    public func artModeIsOn() async throws -> Bool {
        try await connection.request("get_artmode_status")["value"]?.stringValue == "on"
    }

    public func setArtMode(_ on: Bool) async throws {
        try await connection.request("set_artmode_status", params: ["value": .string(on ? "on" : "off")])
    }

    // MARK: Content

    /// Items in `category` (default: My Photos). The unfiltered list repeats personal photos under `M0002`,
    /// so filter by category and dedupe by id. Pass nil for everything (deduped).
    public func contentList(category: String? = ArtProtocol.personalCategory) async throws -> [ContentItem] {
        var params: [String: JSON] = [:]
        if let category { params["category"] = .string(category) }
        return try ContentItem.list(from: try await connection.request("get_content_list", params: params),
                                    category: category)
    }

    public func currentArtwork() async throws -> CurrentArtwork {
        try CurrentArtwork(try await connection.request("get_current_artwork"))
    }

    /// Thumbnail JPEG via the d2d socket (the TV sends it after replying with `conn_info`).
    public func thumbnail(_ contentID: String) async throws -> Data {
        let id = Self.newID()
        let reply = try await connection.request("get_thumbnail", params: [
            "content_id": .string(contentID),
            "conn_info": Self.connInfo(id: id),
        ], id: id)
        let endpoint = try D2DSocket.Endpoint(connInfo: reply)
        return try await D2DSocket.receive(from: endpoint, timeout: .seconds(30)).data
    }

    /// Uploads a JPEG and returns its new content id (e.g. `MY_F0003`).
    /// `send_image` → `ready_to_use` (with `conn_info`) → bytes over the d2d socket → `image_added`.
    /// An exact 3840×2160 image with matte `none` displays full-screen (verified).
    public func upload(jpeg: Data, matte: String = "none", portraitMatte: String = "none",
                       date: Date = Date()) async throws -> String {
        let id = Self.newID()
        // Register for `image_added` first: it can arrive right after the bytes, as a reply or as a broadcast.
        let added = await connection.expect(id: id, includeBroadcasts: true) { $0.event == "image_added" }
        do {
            let ready = try await connection.request("send_image", params: [
                "file_type": "jpg",
                "file_size": .number(Double(jpeg.count)),
                "image_date": .string(Self.imageDate(date)),
                "matte_id": .string(matte),
                "portrait_matte_id": .string(portraitMatte),
                "conn_info": Self.connInfo(id: id),
            ], until: "ready_to_use", id: id)
            try await D2DSocket.send(jpeg, fileType: "jpg", to: D2DSocket.Endpoint(connInfo: ready), timeout: .seconds(60))
            let done = try await connection.wait(for: added, timeout: .seconds(120), what: "`image_added`")
            guard let contentID = done["content_id"]?.stringValue else {
                throw ArtError.unexpectedResponse("image_added without content_id")
            }
            return contentID
        } catch {
            await connection.discard(added)
            throw error
        }
    }

    /// Deletes items and returns the ids the TV confirmed.
    @discardableResult
    public func delete(_ contentIDs: [String]) async throws -> [String] {
        let list = JSON.array(contentIDs.map { ["content_id": .string($0)] })
        let reply = try await connection.request("delete_image_list", params: ["content_id_list": list],
                                                 until: "image_list_deleted")
        return reply["content_id_list"]?.decodedIfString?.arrayValue?.compactMap { $0["content_id"]?.stringValue } ?? []
    }

    /// Shows an item now. With `show: true` the TV also switches into art mode.
    public func select(_ contentID: String, category: String? = ArtProtocol.personalCategory, show: Bool = true) async throws {
        var params: [String: JSON] = ["content_id": .string(contentID), "show": .bool(show)]
        if let category { params["category_id"] = .string(category) }
        try await connection.request("select_image", params: params)
    }

    // MARK: Mattes

    public func matteList() async throws -> MatteList {
        MatteList(try await connection.request("get_matte_list"))
    }

    /// `matte` is `none` or `type_color` (e.g. `modern_polar`). Don't send `portrait_matte_id` here:
    /// this TV rejects it with -7.
    public func changeMatte(_ contentID: String, matte: String) async throws {
        try await connection.request("change_matte", params: ["content_id": .string(contentID), "matte_id": .string(matte)])
    }

    // MARK: Slideshow

    public func slideshowStatus() async throws -> SlideshowStatus {
        SlideshowStatus(try await slideshowRequest("get"))
    }

    /// Turns the slideshow on for `category` every `intervalMinutes`, or off when nil. The TV accepts any interval
    /// without validating it; stick to values its menu offers.
    public func setSlideshow(intervalMinutes: Int?, shuffle: Bool = true,
                             category: String = ArtProtocol.personalCategory) async throws {
        try await slideshowRequest("set", params: [
            "value": .string(intervalMinutes.map(String.init) ?? "off"),
            "category_id": .string(category),
            "type": .string(shuffle ? "shuffleslideshow" : "slideshow"),
        ])
    }

    @discardableResult
    private func slideshowRequest(_ verb: String, params: [String: JSON] = [:]) async throws -> ArtMessage {
        let families = slideshowCommand.map { [$0] } ?? ["auto_rotation_status", "slideshow_status"]
        var lastError: Error = ArtError.unexpectedResponse("no slideshow command")
        for family in families {
            do {
                let reply = try await connection.request("\(verb)_\(family)", params: params)
                slideshowCommand = family
                return reply
            } catch let e as ArtError where e.isUnsupportedRequest {
                lastError = e
            }
        }
        throw lastError
    }

    // MARK: Helpers

    static func newID() -> String { UUID().uuidString.lowercased() }

    static func connInfo(id: String) -> JSON {
        ["d2d_mode": "socket", "connection_id": .number(Double(UInt32.random(in: 0 ... .max))), "id": .string(id)]
    }

    /// `YYYY:MM:DD HH:MM:SS`, local time.
    static func imageDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.string(from: date)
    }
}
