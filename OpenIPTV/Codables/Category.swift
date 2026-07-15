import Foundation

struct Category: Codable {
    var categoryId: String
    var categoryName: String
    var parentId: Int
    
    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case categoryName = "category_name"
        case parentId = "parent_id"
    }
}

extension Category {
    // In an extension so the memberwise init (used by previewData) is preserved.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categoryId = c.flexibleString(.categoryId)
        categoryName = c.flexibleString(.categoryName)
        parentId = c.flexibleInt(.parentId)
    }
}

extension Category {
    static var previewData: [Category] {
        let categories = [
            Category(categoryId: "1", categoryName: "Documentary", parentId: 0),
            Category(categoryId: "2", categoryName: "+18 Adultos", parentId: 0)
        ]
        return categories
    }
    
    static var previewLiveData: [Category] {
        guard let url = Bundle.main.url(forResource: "liveCategories", withExtension: "json") else {
            fatalError("liveCategories.json not found in bundle")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Category].self, from: data)
        } catch {
            fatalError("Failed to decode liveCategories.json: \(error)")
        }
    }
}
