import Foundation
import Testing
@testable import InframyKit

/// Encoding and decoding against frames captured from Matt's TV.
struct ProtocolTests {
    @Test func channelURLMatchesWhatTheTVAccepted() {
        let url = ArtProtocol.channelURL(host: "192.168.5.86")
        #expect(url.absoluteString == "wss://192.168.5.86:8002/api/v2/channels/com.samsung.art-app?name=SW5mcmFteQ%3D%3D")
        let withToken = ArtProtocol.channelURL(host: "10.0.0.2", token: "abc=")
        #expect(withToken.absoluteString.hasSuffix("?name=SW5mcmFteQ%3D%3D&token=abc%3D"))
    }

    @Test func requestEnvelopeCarriesDataAsAString() throws {
        let text = ArtProtocol.encodeRequest("get_content_list", id: "abc", params: ["category": "MY-C0002"])
        let frame = try JSON.parse(text)
        #expect(frame["method"] == "ms.channel.emit")
        #expect(frame["params"]?["event"] == "art_app_request")
        #expect(frame["params"]?["to"] == "host")
        guard case .string(let data)? = frame["params"]?["data"] else {
            Issue.record("data must be a JSON string, not an object")
            return
        }
        let inner = try JSON.parse(data)
        #expect(inner["request"] == "get_content_list")
        #expect(inner["id"] == "abc")
        #expect(inner["request_id"] == "abc")
        #expect(inner["category"] == "MY-C0002")
    }

    @Test func handshakeFrames() throws {
        #expect(try ArtProtocol.decode(Fixture.text("connect")) == .connected(token: nil))
        #expect(try ArtProtocol.decode(Fixture.text("ready")) == .ready)
        #expect(try ArtProtocol.decode(#"{"event":"ms.channel.connect","data":{"token":"12345"}}"#) == .connected(token: "12345"))
        #expect(try ArtProtocol.decode(#"{"event":"ms.channel.unauthorized"}"#) == .refused(event: "ms.channel.unauthorized"))
    }

    @Test func unsupportedRequestError() throws {
        let msg = try Fixture.message("error-unsupported")
        #expect(msg.event == "error")
        #expect(msg.error == .tv(code: "-9", request: "api_version"))
        #expect(msg.error?.isUnsupportedRequest == true)
    }

    @Test func apiVersion() throws {
        #expect(try Fixture.message("api-version")["version"] == "2.03")
    }

    @Test func readyToUseConnInfoIsDoublyEncoded() throws {
        let endpoint = try D2DSocket.Endpoint(connInfo: Fixture.message("ready-to-use"))
        #expect(endpoint == D2DSocket.Endpoint(host: "192.168.5.86", port: 58006, secured: false, key: "REDACTED"))
    }

    @Test func contentListFiltersAndDedupes() throws {
        let reply = try Fixture.message("content-list")
        let personal = try ContentItem.list(from: reply, category: ArtProtocol.personalCategory)
        #expect(personal.map(\.contentID).sorted() == ["MY_F0001", "MY_F0002"])
        #expect(personal.allSatisfy { $0.isPersonal && $0.width == 3840 && $0.height == 2160 && $0.matteID == "none" })
        #expect(personal.first?.contentType == "mobile")
        // Unfiltered: the TV lists each personal photo under both MY-C0002 and M0002 (4 raw entries);
        // dedupe keeps one of each.
        #expect(reply["content_list"]?.decodedIfString?.arrayValue?.count == 4)
        let all = try ContentItem.list(from: reply, category: nil)
        #expect(all.map(\.contentID).sorted() == ["MY_F0001", "MY_F0002"])
    }

    @Test func slideshowStatus() throws {
        let on = SlideshowStatus(try Fixture.message("auto-rotation-15"))
        #expect(on.intervalMinutes == 15)
        #expect(on.isShuffle)
        #expect(on.categoryID == "MY-C0002")
        #expect(on.currentContentID == "MY_F0002")
        #expect(Set(on.contentIDs) == ["MY_F0001", "MY_F0002"])
        let off = SlideshowStatus(try Fixture.message("auto-rotation-off"))
        #expect(!off.isOn)
        #expect(off.categoryID == nil && off.type == nil && off.contentIDs.isEmpty)
    }

    @Test func imageAddedComesTwice() throws {
        let reply = try Fixture.message("image-added")
        let broadcast = try Fixture.message("image-added-broadcast")
        #expect(reply.id != nil)
        #expect(broadcast.id == nil)
        #expect(reply["content_id"] == broadcast["content_id"])
        #expect(reply["width"] == "3840")  // a string here, a number in get_content_list
    }

    @Test func mattes() throws {
        let list = MatteList(try Fixture.message("matte-list"))
        #expect(list.types.first == "none")
        #expect(list.types.contains("modernthin"))
        #expect(list.colors.contains("polar"))
        #expect(list.colors.count == 16)
    }

    @Test func currentArtwork() throws {
        let current = try CurrentArtwork(Fixture.message("current-artwork"))
        #expect(!current.contentID.isEmpty)
        #expect(current.matteID != nil)
    }

    @Test func uploadHeaderFraming() throws {
        let header = D2DSocket.uploadHeader(fileLength: 5, fileType: "jpg", key: "abc")
        let framed = D2DSocket.frame(header: header, body: Data("hello".utf8))
        #expect(Array(framed.prefix(4)) == [0, 0, 0, UInt8(header.count)])
        let parsed = try JSON.parse(framed.subdata(in: 4..<(4 + header.count)))
        #expect(parsed["fileLength"]?.intValue == 5)
        #expect(parsed["secKey"] == "abc")
        #expect(parsed["fileType"] == "jpg")
        #expect(parsed["num"]?.intValue == 0 && parsed["total"]?.intValue == 1)
        #expect(framed.suffix(5) == Data("hello".utf8))
    }

    @Test func restDeviceInfo() throws {
        let json = try JSON.parse(#"""
        {"device":{"FrameTVSupport":"true","id":"uuid:94b1","ip":"192.168.5.86","modelName":"QN55LS03TAFXZA",
         "name":"[TV] The Frame","wifiMac":"5C:C1:D7:62:D2:12","PowerState":"on"},"id":"uuid:94b1"}
        """#)
        let info = try #require(TVDeviceInfo(json: json, host: "fallback"))
        #expect(info.isFrame && info.host == "192.168.5.86" && info.wifiMAC == "5C:C1:D7:62:D2:12")
        #expect(info.id == "uuid:94b1")
    }

    @Test func wakeOnLANPacket() throws {
        let packet = try WakeOnLAN.magicPacket(mac: "5C:C1:D7:62:D2:12")
        #expect(packet.count == 102)
        #expect(packet.prefix(6).allSatisfy { $0 == 0xFF })
        #expect(Array(packet[6..<12]) == [0x5C, 0xC1, 0xD7, 0x62, 0xD2, 0x12])
        #expect(throws: (any Error).self) { try WakeOnLAN.magicPacket(mac: "nope") }
    }
}

@Suite struct HostileInputTests {
    @Test func hugeNumbersDontCrash() throws {
        let json = try JSON.parse(Data(#"{"id": 1e300, "port": -1e19, "n": 42}"#.utf8))
        #expect(json["id"]?.stringValue != nil)
        #expect(json["id"]?.intValue == nil)
        #expect(json["port"]?.intValue == nil)
        #expect(json["n"]?.stringValue == "42")
    }

    @Test func contentIDsAreSafeFileNames() {
        #expect(ContentItem.fileName(for: "MY_F0004") == "MY_F0004")
        #expect(ContentItem.fileName(for: "../../etc/passwd") == "______etc_passwd")
        #expect(!ContentItem.fileName(for: "a/b").contains("/"))
        #expect(ContentItem.fileName(for: "") == "item")
    }
}
