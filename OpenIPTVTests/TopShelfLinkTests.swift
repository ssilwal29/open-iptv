import Foundation
import Testing
@testable import OpenIPTV

@Suite("Top Shelf deep links")
struct TopShelfLinkTests {
    @Test func movieLinkRoundTrips() throws {
        let link = TopShelfLink(profileId: "ABC-123", target: .movie(streamId: 42), play: true)
        let parsed = try #require(TopShelfLink(url: link.url))
        #expect(parsed == link)
        #expect(link.url.scheme == "openiptvapp")
    }

    @Test func episodeLinkRoundTripsWithSpecialCharacters() throws {
        let link = TopShelfLink(profileId: "p", target: .episode(seriesId: 7, episodeId: "ep 1&2"), play: false)
        let parsed = try #require(TopShelfLink(url: link.url))
        #expect(parsed == link)
        #expect(!parsed.play)
    }

    @Test func rejectsForeignOrIncompleteURLs() throws {
        #expect(TopShelfLink(url: try #require(URL(string: "https://open?profile=p&kind=movie&id=1"))) == nil)
        #expect(TopShelfLink(url: try #require(URL(string: "openiptvapp://open?kind=movie&id=1"))) == nil)
        #expect(TopShelfLink(url: try #require(URL(string: "openiptvapp://open?profile=p&kind=movie&id=x"))) == nil)
        #expect(TopShelfLink(url: try #require(URL(string: "openiptvapp://open?profile=p&kind=live&id=1"))) == nil)
    }
}
