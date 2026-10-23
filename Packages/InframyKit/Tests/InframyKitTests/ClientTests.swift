import Foundation
import Testing
@testable import InframyKit

/// ArtClient end to end against a fake TV on 127.0.0.1 (never the real TV).
@Suite(.serialized)
struct ClientTests {
    @Test func versionFallsBackToLegacyRequest() async throws {
        let tv = try await FakeTV { req, _ in
            switch req.name {
            case "api_version": return [try Fixture.reply("error-unsupported", id: req.id)]
            case "get_api_version": return [try Fixture.reply("api-version", id: req.id)]
            default: return []
            }
        }
        defer { tv.stop() }
        let version = try await tv.client().apiVersion()
        #expect(version == "2.03")
        #expect(tv.requests.map(\.name) == ["api_version", "get_api_version"])
    }

    @Test func requestsReuseOneConnection() async throws {
        let tv = try await FakeTV { req, _ in
            [try Fixture.reply(req.name == "get_content_list" ? "content-list" : "current-artwork", id: req.id)]
        }
        defer { tv.stop() }
        let client = tv.client()
        _ = try await client.contentList()
        _ = try await client.currentArtwork()
        _ = try await client.contentList()
        #expect(tv.connectionCount == 1)
        #expect(tv.requests.first?.params["category"] == "MY-C0002")
    }

    @Test func repliesAreMatchedById() async throws {
        // A broadcast and another request's reply arrive first; the client must wait for its own id.
        let tv = try await FakeTV { req, _ in
            [Frame.d2d(["event": "go_to_standby"]),
             try Fixture.reply("current-artwork", id: "someone-else"),
             try Fixture.reply("api-version", id: req.id)]
        }
        defer { tv.stop() }
        let client = tv.client()
        let broadcasts = await client.connection.broadcasts()
        #expect(try await client.apiVersion() == "2.03")
        var iterator = broadcasts.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.event == "go_to_standby")
    }

    @Test func tvErrorsSurfaceWithCode() async throws {
        let tv = try await FakeTV { req, _ in [Frame.error(id: req.id, request: req.name, code: "-7")] }
        defer { tv.stop() }
        await #expect(throws: ArtError.tv(code: "-7", request: "change_matte")) {
            try await tv.client().changeMatte("MY_F0001", matte: "none")
        }
        // change_matte must not send portrait_matte_id: this TV rejects it with -7.
        #expect(tv.requests.first?.params["portrait_matte_id"] == nil)
        #expect(tv.requests.first?.params["matte_id"] == "none")
    }

    @Test func timesOutWhenTheTVIsSilent() async throws {
        let tv = try await FakeTV { _, _ in [] }
        defer { tv.stop() }
        await #expect(throws: ArtError.timedOut("`get_api_version`")) {
            _ = try await tv.client(timeout: .milliseconds(300)).connection.request("get_api_version")
        }
    }

    @Test func uploadSendsBytesOverD2DAndReturnsContentID() async throws {
        let jpeg = Data((0..<50_000).map { UInt8($0 % 251) })
        let tvBox = Box<FakeTV>()
        let idBox = Box<String>()
        let d2d = try await FakeD2D(mode: .receive) { _ in
            // After the bytes land, the TV sends image_added as a reply and again as a broadcast.
            let id = idBox.value!
            tvBox.value?.broadcast(Frame.d2d(["id": .string(id), "event": "image_added", "content_id": "MY_F0003",
                                              "matte_id": "none", "width": "3840", "height": "2160"]))
            tvBox.value?.broadcast(Frame.d2d(["event": "image_added", "content_id": "MY_F0003",
                                              "category_id": "MY-C0002"]))
        }
        defer { d2d.stop() }
        let tv = try await FakeTV { req, _ in
            guard req.name == "send_image" else { return [] }
            idBox.value = req.id
            return [Frame.readyToUse(id: req.id, port: d2d.port, key: "s3cret")]
        }
        tvBox.value = tv
        defer { tv.stop() }

        let contentID = try await tv.client().upload(jpeg: jpeg)
        #expect(contentID == "MY_F0003")

        let req = try #require(tv.requests.first)
        #expect(req.params["file_type"] == "jpg")
        #expect(req.params["file_size"]?.intValue == jpeg.count)
        #expect(req.params["matte_id"] == "none")
        #expect(req.params["portrait_matte_id"] == "none")
        #expect(req.params["conn_info"]?["d2d_mode"] == "socket")
        #expect(req.params["conn_info"]?["id"]?.stringValue == req.id)
        #expect(req.params["image_date"]?.stringValue?.count == 19)

        let received = d2d.received
        let headerLength = Int(received.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        let header = try JSON.parse(received.subdata(in: 4..<(4 + headerLength)))
        #expect(header["secKey"] == "s3cret")
        #expect(header["fileLength"]?.intValue == jpeg.count)
        #expect(received.suffix(from: 4 + headerLength) == jpeg)
    }

    @Test func uploadFailsCleanlyWhenTVRejects() async throws {
        let tv = try await FakeTV { req, _ in [Frame.error(id: req.id, request: "send_image", code: "-1")] }
        defer { tv.stop() }
        await #expect(throws: ArtError.tv(code: "-1", request: "send_image")) {
            _ = try await tv.client().upload(jpeg: Data([1, 2, 3]))
        }
    }

    @Test func thumbnailComesOverD2D() async throws {
        let body = Data((0..<4096).map { UInt8($0 % 200) })
        let d2d = try await FakeD2D(mode: .send(header: ["fileID": "MY_F0001", "fileType": "jpg", "num": 0,
                                                          "total": 1, "fileLength": .number(Double(body.count))],
                                                 body: body))
        defer { d2d.stop() }
        let tv = try await FakeTV { req, _ in
            req.name == "get_thumbnail" ? [Frame.readyToUse(id: req.id, port: d2d.port)] : []
        }
        defer { tv.stop() }
        let thumb = try await tv.client().thumbnail("MY_F0001")
        #expect(thumb == body)
        #expect(tv.requests.first?.params["content_id"] == "MY_F0001")
    }

    @Test func deleteReturnsConfirmedIDs() async throws {
        let tv = try await FakeTV { req, _ in
            [Frame.d2d(["event": "image_deleted", "content_id": "MY_F0001"]),
             Frame.d2d(["event": "image_deleted", "content_id": "MY_F0002"]),
             try Fixture.reply("image-list-deleted", id: req.id)]
        }
        defer { tv.stop() }
        let deleted = try await tv.client().delete(["MY_F0001", "MY_F0002"])
        #expect(deleted == ["MY_F0001", "MY_F0002"])
        let sent = tv.requests.first?.params["content_id_list"]?.arrayValue?.compactMap { $0["content_id"]?.stringValue }
        #expect(sent == ["MY_F0001", "MY_F0002"])
    }

    @Test func slideshowUsesOlderCommandNames() async throws {
        let tv = try await FakeTV { req, _ in
            switch req.name {
            case "set_auto_rotation_status":
                // The real TV sends the broadcast copy first, then the reply with our id.
                return [try Fixture.text("auto-rotation-changed-broadcast"),
                        try Fixture.reply("auto-rotation-changed", id: req.id)]
            case "get_auto_rotation_status": return [try Fixture.reply("auto-rotation-15", id: req.id)]
            default: return [Frame.error(id: req.id, request: req.name, code: "-9")]
            }
        }
        defer { tv.stop() }
        let client = tv.client()
        try await client.setSlideshow(intervalMinutes: 15)
        let status = try await client.slideshowStatus()
        #expect(status.intervalMinutes == 15)
        let set = try #require(tv.requests.first)
        #expect(set.name == "set_auto_rotation_status")
        #expect(set.params["value"] == "15")
        #expect(set.params["category_id"] == "MY-C0002")
        #expect(set.params["type"] == "shuffleslideshow")

        try await client.setSlideshow(intervalMinutes: nil)
        #expect(tv.requests.last?.params["value"] == "off")
    }

    @Test func slideshowFallsBackToNewerCommandNames() async throws {
        let tv = try await FakeTV { req, _ in
            if req.name.hasSuffix("auto_rotation_status") { return [Frame.error(id: req.id, request: req.name, code: "-9")] }
            return [Frame.d2d(["id": .string(req.id), "event": "slideshow_status", "value": "60",
                               "category_id": "MY-C0002", "type": "slideshow"])]
        }
        defer { tv.stop() }
        let client = tv.client()
        let status = try await client.slideshowStatus()
        #expect(status.intervalMinutes == 60 && !status.isShuffle)
        _ = try await client.slideshowStatus()
        // The working family is remembered: the second call goes straight to slideshow_status.
        #expect(tv.requests.map(\.name) == ["get_auto_rotation_status", "get_slideshow_status", "get_slideshow_status"])
    }

    @Test func selectShowsInPersonalCategory() async throws {
        let tv = try await FakeTV { req, _ in [try Fixture.reply("image-selected", id: req.id)] }
        defer { tv.stop() }
        try await tv.client().select("MY_F0001")
        let req = try #require(tv.requests.first)
        #expect(req.name == "select_image")
        #expect(req.params["show"] == true)
        #expect(req.params["category_id"] == "MY-C0002")
    }
}

final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T?
    var value: T? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
