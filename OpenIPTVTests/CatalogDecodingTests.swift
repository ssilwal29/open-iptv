import Foundation
import Testing
@testable import OpenIPTV

/// The sample payloads bundled with the app (used by previews) decode with
/// the lenient decoders.
@Suite("Catalog decoding")
struct CatalogDecodingTests {
    @Test func sampleLiveChannelsDecode() {
        #expect(!Live.previewData.isEmpty)
    }

    @Test func liveDecodesNumbersSentAsStrings() throws {
        let json = """
        [{"num":"3","name":"News","stream_type":"live","stream_id":"101","stream_icon":"",
        "epg_channel_id":null,"added":"0","is_adult":"0","category_id":5,"tv_archive":"1","direct_source":""}]
        """
        let live = try #require(try JSONDecoder().decode([Live].self, from: Data(json.utf8)).first)
        #expect(live.num == 3)
        #expect(live.streamId == 101)
        #expect(live.categoryId == "5")
        #expect(live.tvArchive == 1)
        #expect(live.epgChannelId == nil)
    }
}
