import Foundation
import Testing
@testable import OpenIPTV

@Suite("EPG decoding")
struct EPGTests {
    private func decode(_ json: String) throws -> EPGResponse {
        try JSONDecoder().decode(EPGResponse.self, from: Data(json.utf8))
    }

    @Test func decodesBase64TitlesAndTimestamps() throws {
        // "Evening News" / "Top stories" in base64.
        let json = """
        {"epg_listings":[{"id":"1","title":"RXZlbmluZyBOZXdz","description":"VG9wIHN0b3JpZXM=",
        "start":"2024-05-01 20:00:00","end":"2024-05-01 21:00:00",
        "start_timestamp":"1714593600","stop_timestamp":"1714597200","has_archive":1}]}
        """
        let listing = try #require(try decode(json).listings.first)
        #expect(listing.title == "Evening News")
        #expect(listing.description == "Top stories")
        #expect(listing.start == Date(timeIntervalSince1970: 1_714_593_600))
        #expect(listing.end == Date(timeIntervalSince1970: 1_714_597_200))
        #expect(listing.hasArchive)
        #expect(listing.durationMinutes == 60)
    }

    @Test func keepsPlainTextTitles() throws {
        let json = """
        {"epg_listings":[{"id":"2","title":"Match of the Day!","description":"",
        "start":"2024-05-01 20:00:00","end":"2024-05-01 21:30:00",
        "start_timestamp":1714593600,"stop_timestamp":1714599000}]}
        """
        let listing = try #require(try decode(json).listings.first)
        #expect(listing.title == "Match of the Day!")
        #expect(listing.durationMinutes == 90)
        #expect(!listing.hasArchive)
    }

    @Test func toleratesPanelsWithNoGuide() throws {
        #expect(try decode("[]").listings.isEmpty)
        #expect(try decode("{}").listings.isEmpty)
        #expect(try decode(#"{"epg_listings":false}"#).listings.isEmpty)
    }

    @Test func skipsMalformedListingsInsteadOfFailing() throws {
        let json = """
        {"epg_listings":[42,{"id":"3","title":"Ok","start":"2024-05-01 20:00:00","end":"2024-05-01 20:30:00",
        "start_timestamp":1714593600,"stop_timestamp":1714595400}]}
        """
        #expect(try decode(json).listings.map(\.title) == ["Ok"])
    }

    @Test func timeshiftStartUsesServerLocalString() {
        let listing = EPGListing(
            id: "x", title: "T", description: "",
            start: .now, end: .now.addingTimeInterval(1800),
            serverStart: "2024-05-01 20:05:00", hasArchive: true
        )
        #expect(listing.timeshiftStart == "2024-05-01:20-05")

        let odd = EPGListing(
            id: "y", title: "T", description: "",
            start: .now, end: .now, serverStart: "20:05", hasArchive: true
        )
        #expect(odd.timeshiftStart == nil)
    }

    @Test func progressIsClampedAndAiringIsHalfOpen() {
        let start = Date(timeIntervalSince1970: 1000)
        let listing = EPGListing(
            id: "z", title: "T", description: "",
            start: start, end: start.addingTimeInterval(100),
            serverStart: "", hasArchive: false
        )
        #expect(listing.progress(at: start.addingTimeInterval(50)) == 0.5)
        #expect(listing.progress(at: start.addingTimeInterval(-10)) == 0)
        #expect(listing.progress(at: start.addingTimeInterval(500)) == 1)
        #expect(listing.isAiring(at: start))
        #expect(!listing.isAiring(at: start.addingTimeInterval(100)))
    }

    @Test func timeshiftURLEscapesCredentials() throws {
        let credentials = XtreamCredentials(serverURL: "http://example.com:8080/", username: "user", password: "p/ss word")
        let listing = EPGListing(
            id: "a", title: "T", description: "",
            start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600),
            serverStart: "2024-05-01 20:00:00", hasArchive: true
        )
        let url = try #require(XtreamAPIService.timeshiftURL(credentials: credentials, streamId: 77, listing: listing))
        #expect(url.absoluteString == "https://example.com:8080/timeshift/user/p%2Fss%20word/60/2024-05-01:20-00/77.m3u8")
    }
}
