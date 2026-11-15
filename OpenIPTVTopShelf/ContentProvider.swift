import TVServices

/// Top Shelf "Continue Watching" row, built from the snapshot the app writes
/// to the shared App Group container (see `TopShelfShared`).
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let snapshot = TopShelfSnapshot.load(), !snapshot.items.isEmpty else {
            // nil → tvOS shows the app's static Top Shelf image.
            completionHandler(nil)
            return
        }

        let items: [TVTopShelfSectionedItem] = snapshot.items.map { entry in
            let item = TVTopShelfSectionedItem(identifier: entry.id)
            item.title = entry.subtitle.map { "\(entry.title) · \($0)" } ?? entry.title
            item.imageShape = entry.kind == .movie ? .poster : .hdtv
            if let imageURL = entry.imageURL {
                item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
            }
            item.playbackProgress = entry.progress
            item.displayAction = TVTopShelfAction(url: entry.displayURL)
            item.playAction = TVTopShelfAction(url: entry.playURL)
            return item
        }

        let section = TVTopShelfItemCollection(items: items)
        section.title = "Continue Watching"
        completionHandler(TVTopShelfSectionedContent(sections: [section]))
    }
}
