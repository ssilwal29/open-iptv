import Foundation

struct Live: Codable {
    var num: Int
    var name: String
    var streamType: String
    var streamId: Int
    var streamIcon: String
    var epgChannelId: String?
    var added: String
    var adult: String
    var categoryId: String?
    var customSid: String?
    var tvArchive: Int
    var directSource: String

    enum CodingKeys: String, CodingKey {
        case num
        case name
        case streamType = "stream_type"
        case streamId = "stream_id"
        case streamIcon = "stream_icon"
        case epgChannelId = "epg_channel_id"
        case added
        case adult = "is_adult"
        case categoryId = "category_id"
        case customSid = "custom_sid"
        case tvArchive = "tv_archive"
        case directSource = "direct_source"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        num = c.flexibleInt(.num)
        name = c.flexibleString(.name)
        streamType = c.flexibleString(.streamType)
        streamId = c.flexibleInt(.streamId)
        streamIcon = c.flexibleString(.streamIcon)
        epgChannelId = c.flexibleStringOptional(.epgChannelId)
        added = c.flexibleString(.added)
        adult = c.flexibleString(.adult)
        categoryId = c.flexibleStringOptional(.categoryId)
        customSid = c.flexibleStringOptional(.customSid)
        tvArchive = c.flexibleInt(.tvArchive)
        directSource = c.flexibleString(.directSource)
    }

    var streamIconURL: URL? {
        guard let url = URL(string: streamIcon) else {
            return nil
        }
        return url
    }
}

extension Live: Identifiable, Hashable {
    public var id: String { num.description }
}

extension Live {
    
    static var previewData: [Live] {
        guard let url = Bundle.main.url(forResource: "lives", withExtension: "json") else {
            fatalError("lives.json not found in bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Live].self, from: data)
        } catch {
            fatalError("Failed to decode lives.json: \(error)")
        }
    }
    
}
