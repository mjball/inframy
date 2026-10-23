import Foundation

/// One item from `get_content_list`. Numbers arrive as numbers here but as strings in `image_added`, so read leniently.
public struct ContentItem: Sendable, Equatable, Hashable {
    public var contentID: String
    public var categoryID: String
    public var matteID: String?
    public var portraitMatteID: String?
    public var width: Int?
    public var height: Int?
    public var imageDate: String?
    /// e.g. `mobile` (uploaded over the API), `preinstall`, `usb`, `ambient`.
    public var contentType: String?

    public init?(_ json: JSON) {
        guard let id = json["content_id"]?.stringValue else { return nil }
        contentID = id
        categoryID = json["category_id"]?.stringValue ?? ""
        matteID = json["matte_id"]?.stringValue
        portraitMatteID = json["portrait_matte_id"]?.stringValue
        width = json["width"]?.intValue
        height = json["height"]?.intValue
        imageDate = json["image_date"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        contentType = json["content_type"]?.stringValue
    }

    /// Parses a `get_content_list` reply. The unfiltered list repeats personal photos under `M0002`, so this
    /// filters by `category` (nil = all) and dedupes by id.
    public static func list(from reply: ArtMessage, category: String?) throws -> [ContentItem] {
        guard let list = reply["content_list"]?.decodedIfString?.arrayValue else {
            throw ArtError.unexpectedResponse("no content_list")
        }
        var seen = Set<String>()
        return list.compactMap(ContentItem.init).filter { item in
            (category == nil || item.categoryID == category) && seen.insert(item.contentID).inserted
        }
    }

    /// Personal uploads have ids like `MY_F0001` (this TV) or `MY-F0020` (other firmware).
    public var isPersonal: Bool { contentID.hasPrefix("MY_") || contentID.hasPrefix("MY-") }
}

public struct CurrentArtwork: Sendable, Equatable {
    public var contentID: String
    public var matteID: String?
    public var portraitMatteID: String?

    public init(_ reply: ArtMessage) throws {
        guard let id = reply["content_id"]?.stringValue else { throw ArtError.unexpectedResponse("no content_id") }
        contentID = id
        matteID = reply["matte_id"]?.stringValue
        portraitMatteID = reply["portrait_matte_id"]?.stringValue
    }
}

public struct SlideshowStatus: Sendable, Equatable {
    /// Minutes between changes, or nil when off.
    public var intervalMinutes: Int?
    public var categoryID: String?
    /// `shuffleslideshow` or `slideshow`.
    public var type: String?
    public var currentContentID: String?
    public var contentIDs: [String]

    public init(_ reply: ArtMessage) {
        let value = reply["value"]?.stringValue ?? "off"
        intervalMinutes = value == "off" ? nil : Int(value)
        categoryID = reply["category_id"]?.nonEmptyString
        type = reply["type"]?.nonEmptyString
        currentContentID = reply["current_content_id"]?.nonEmptyString
        contentIDs = reply["content_list"]?.decodedIfString?.arrayValue?.compactMap { $0["content_id"]?.stringValue } ?? []
    }

    public var isOn: Bool { intervalMinutes != nil }
    public var isShuffle: Bool { type == "shuffleslideshow" }
}

public struct MatteList: Sendable, Equatable {
    public var types: [String]
    public var colors: [String]

    /// Older firmware calls the type list `matte_list`; both are JSON documents in strings.
    public init(_ reply: ArtMessage) {
        types = (reply["matte_type_list"] ?? reply["matte_list"])?.decodedIfString?.arrayValue?
            .compactMap { $0["matte_type"]?.stringValue } ?? []
        colors = reply["matte_color_list"]?.decodedIfString?.arrayValue?.compactMap { $0["color"]?.stringValue } ?? []
    }
}

extension JSON {
    var nonEmptyString: String? { stringValue.flatMap { $0.isEmpty ? nil : $0 } }
}
