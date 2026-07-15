import Foundation
import SwiftData

enum ContentKind: String, Codable, CaseIterable {
    case movie
    case serie
    case live
}

@Model
final class CategoryEntity {
    var compositeId: String
    var categoryId: String
    var name: String
    var kindRaw: String
    var sortOrder: Int
    var lastSeenAt: Date

    var profile: Profile?

    @Relationship(deleteRule: .cascade, inverse: \MovieEntity.category) var movies: [MovieEntity] = []
    @Relationship(deleteRule: .cascade, inverse: \SerieEntity.category) var series: [SerieEntity] = []
    @Relationship(deleteRule: .cascade, inverse: \LiveEntity.category) var lives: [LiveEntity] = []

    var kind: ContentKind {
        ContentKind(rawValue: kindRaw) ?? .movie
    }

    init(
        categoryId: String,
        name: String,
        kind: ContentKind,
        sortOrder: Int = 0,
        lastSeenAt: Date = .now,
        profile: Profile? = nil
    ) {
        self.compositeId = Self.compositeId(kind: kind, categoryId: categoryId)
        self.categoryId = categoryId
        self.name = name
        self.kindRaw = kind.rawValue
        self.sortOrder = sortOrder
        self.lastSeenAt = lastSeenAt
        self.profile = profile
    }

    static func compositeId(kind: ContentKind, categoryId: String) -> String {
        "\(kind.rawValue):\(categoryId)"
    }
}
