import Foundation
import Testing
@testable import OpenIPTV

@Suite("EPG AI formatting")
struct EPGFormatterTests {
    @Test func parsesWrappedFencedAndBareJSON() throws {
        let wrapped = #"{"programmes":[{"id":"0","title":"News at Ten","episode":null,"genre":"News","summary":"Headlines.","tags":["Live"]}]}"#
        #expect(try EPGFormatterPrompt.parse(wrapped).first?.title == "News at Ten")

        let fenced = "Here you go:\n```json\n" + wrapped + "\n```"
        #expect(try EPGFormatterPrompt.parse(fenced).count == 1)

        let bare = #"[{"id":1,"title":"Match Day","episode":"S2 E5","genre":null,"summary":null,"tags":[]}]"#
        let item = try #require(try EPGFormatterPrompt.parse(bare).first)
        #expect(item.id == "1")
        #expect(item.episode == "S2 E5")
    }

    @Test func rejectsNonJSON() {
        #expect(throws: (any Error).self) { try EPGFormatterPrompt.parse("Sorry, I can't help with that.") }
    }

    @Test func programmeIsValidatedAndClamped() throws {
        let output = EPGFormatterPrompt.OutputItem(
            id: "0",
            title: "  Evening News  ",
            episode: "null",
            genre: " News ",
            summary: String(repeating: "a", count: 1000),
            tags: ["Live", "Exclusive", "New", "Repeat", "Final"]
        )
        let programme = try #require(EPGFormatterPrompt.programme(from: output))
        #expect(programme.title == "Evening News")
        #expect(programme.episode == nil)
        #expect(programme.genre == "News")
        #expect(programme.summary?.count == 400)
        #expect(programme.tags == ["Live", "New", "Repeat"])

        let blank = EPGFormatterPrompt.OutputItem(id: "1", title: "   ", episode: nil, genre: nil, summary: nil, tags: nil)
        #expect(EPGFormatterPrompt.programme(from: blank) == nil)
    }

    @Test func cacheKeyDependsOnTextOnly() {
        let a = EPGFormatterPrompt.cacheKey(title: "News", description: "x")
        #expect(a == EPGFormatterPrompt.cacheKey(title: "News", description: "x"))
        #expect(a != EPGFormatterPrompt.cacheKey(title: "News", description: "y"))
        #expect(a.count == 64)
    }

    @Test func userMessageCarriesOnlyGuideText() throws {
        let message = EPGFormatterPrompt.userMessage(for: [
            .init(id: "0", title: "NEWS [HD]", description: "Top stories")
        ])
        #expect(message.contains(#""title":"NEWS [HD]""#))
        #expect(message.contains(#""id":"0""#))
    }
}

// MARK: - OpenRouter client against a stubbed transport

/// Serves canned responses for openrouter.ai requests in these tests.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requestBodies: [Data] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            Self.requestBodies.append(data)
        } else if let body = request.httpBody {
            Self.requestBodies.append(body)
        }
        let next = Self.responses.isEmpty ? (500, "{}") : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("OpenRouter client", .serialized)
struct OpenRouterClientTests {
    private func client() -> OpenRouterClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return OpenRouterClient(apiKey: "test", model: "google/gemini-3.8-flash", session: URLSession(configuration: config))
    }

    private func reset(_ responses: [(Int, String)]) {
        StubURLProtocol.responses = responses.map { (status: $0.0, body: $0.1) }
        StubURLProtocol.requestBodies = []
    }

    @Test func returnsContentAndUsage() async throws {
        reset([(200, #"{"choices":[{"message":{"content":"{\"programmes\":[]}"}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}"#)])
        let (content, usage) = try await client().complete(system: "s", user: "u", schema: EPGFormatterPrompt.schema)
        #expect(content == #"{"programmes":[]}"#)
        #expect(usage?.total == 15)
        let body = try #require(StubURLProtocol.requestBodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "google/gemini-3.8-flash")
        #expect(json["response_format"] != nil)
    }

    @Test func mapsAuthAndCreditErrors() async {
        reset([(401, #"{"error":{"code":401,"message":"No auth"}}"#)])
        await #expect(throws: OpenRouterClient.ClientError.invalidKey) {
            try await client().complete(system: "s", user: "u", schema: nil)
        }
        reset([(402, #"{"error":{"code":402,"message":"Insufficient credits"}}"#)])
        await #expect(throws: OpenRouterClient.ClientError.outOfCredits) {
            try await client().complete(system: "s", user: "u", schema: nil)
        }
    }

    @Test func retriesWithoutStructuredOutputOn400() async throws {
        reset([
            (400, #"{"error":{"code":400,"message":"response_format not supported"}}"#),
            (200, #"{"choices":[{"message":{"content":"[]"}}]}"#)
        ])
        let (content, _) = try await client().complete(system: "s", user: "u", schema: EPGFormatterPrompt.schema)
        #expect(content == "[]")
        #expect(StubURLProtocol.requestBodies.count == 2)
        let retry = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.requestBodies[1]) as? [String: Any])
        #expect(retry["response_format"] == nil)
    }

    @Test func errorInsideSuccessfulResponseIsSurfaced() async {
        reset([(200, #"{"error":{"code":402,"message":"Insufficient credits"}}"#)])
        await #expect(throws: OpenRouterClient.ClientError.outOfCredits) {
            try await client().complete(system: "s", user: "u", schema: nil)
        }
    }
}
