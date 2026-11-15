import Foundation
import SwiftData

@Model
final class LiveEntity {
    var streamId: Int
    var num: Int
    var name: String
    var streamType: String
    var streamIcon: String
    var epgChannelId: String?
    var added: String
    var adult: String
    var categoryId: String
    var customSid: String?
    var tvArchive: Int
    var directSource: String
    var lastSeenAt: Date

    var profile: Profile?
    var category: CategoryEntity?

    var streamIconURL: URL? { streamIcon.secureURL }

    /// Xtream sends `is_adult` as "1"/"0".
    var isAdult: Bool { adult == "1" }

    /// Channels without an EPG id never have guide data, so skip the request.
    var hasGuide: Bool { !(epgChannelId ?? "").isEmpty }

    /// Panel keeps a catch-up archive for this channel.
    var hasCatchup: Bool { tvArchive == 1 }

    init(
        streamId: Int,
        num: Int,
        name: String,
        streamType: String,
        streamIcon: String,
        epgChannelId: String?,
        added: String,
        adult: String,
        categoryId: String,
        customSid: String?,
        tvArchive: Int,
        directSource: String,
        lastSeenAt: Date = .now,
        category: CategoryEntity? = nil,
        profile: Profile? = nil
    ) {
        self.streamId = streamId
        self.num = num
        self.name = name
        self.streamType = streamType
        self.streamIcon = streamIcon
        self.epgChannelId = epgChannelId
        self.added = added
        self.adult = adult
        self.categoryId = categoryId
        self.customSid = customSid
        self.tvArchive = tvArchive
        self.directSource = directSource
        self.lastSeenAt = lastSeenAt
        self.category = category
        self.profile = profile
    }
}
