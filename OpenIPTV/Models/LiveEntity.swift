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
