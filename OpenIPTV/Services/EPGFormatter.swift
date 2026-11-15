import Foundation
import CryptoKit
import OSLog

private let logger = Logger(subsystem: "com.openiptv.app", category: "EPGFormatter")

// MARK: - Result model

/// A guide entry after AI clean-up. Every field falls back to the raw listing
/// when missing.
struct FormattedProgramme: Codable, Hashable {
    let title: String
    let episode: String?
    let genre: String?
    let summary: String?
    let tags: [String]
    var savedAt: Date = .now
}

/// What views render for a programme: AI-formatted when available, raw
/// otherwise.
struct EPGDisplay: Equatable {
    let title: String
    let episode: String?
    let genre: String?
    let summary: String
    let tags: [String]
    let isFormatted: Bool
}

// MARK: - Prompt + parsing (pure, unit-tested)

enum EPGFormatterPrompt {
    /// Bump when the prompt or schema changes so cached results are redone.
    static let version = "v1"

    static let allowedTags = ["Live", "New", "Repeat", "Premiere", "Final"]

    static let system = """
    You clean up TV guide (EPG) entries supplied by IPTV providers. For every input \
    programme return one output with the same id.

    - title: the programme's proper name in natural title case. Remove channel names, \
    quality or status markers (HD, FHD, UHD, 4K, [LIVE], (NEW), *, |), ratings, \
    season/episode codes, dates and repeated punctuation. Keep the original language — \
    never translate. Never invent or guess a different name; if unsure keep the input \
    wording with only casing and clutter fixed.
    - episode: "S2 E5" when season and episode are both given, "Episode 12" when only an \
    episode number is given, otherwise null. Only use numbers present in the input.
    - genre: one of News, Sport, Film, Series, Kids, Documentary, Music, Entertainment, \
    Lifestyle, Religion — only when clearly implied, otherwise null.
    - summary: the description rewritten as at most two plain sentences in the same \
    language, without adding facts. null when there is no meaningful description.
    - tags: zero to three of Live, New, Repeat, Premiere, Final, only when the input says so.
    """

    /// Strict JSON schema for structured output.
    static var schema: [String: Any] {
        let nullableString: [String: Any] = ["type": ["string", "null"]]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["programmes"],
            "properties": [
                "programmes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "title", "episode", "genre", "summary", "tags"],
                        "properties": [
                            "id": ["type": "string"],
                            "title": ["type": "string"],
                            "episode": nullableString,
                            "genre": nullableString,
                            "summary": nullableString,
                            "tags": ["type": "array", "items": ["type": "string", "enum": allowedTags]]
                        ]
                    ]
                ]
            ]
        ]
    }

    struct InputItem: Encodable, Equatable {
        let id: String
        let title: String
        let description: String
    }

    struct OutputItem: Decodable, Equatable {
        let id: String
        let title: String?
        let episode: String?
        let genre: String?
        let summary: String?
        let tags: [String]?

        enum CodingKeys: String, CodingKey { case id, title, episode, genre, summary, tags }

        init(id: String, title: String?, episode: String?, genre: String?, summary: String?, tags: [String]?) {
            self.id = id
            self.title = title
            self.episode = episode
            self.genre = genre
            self.summary = summary
            self.tags = tags
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.flexibleString(.id)
            title = try? c.decode(String.self, forKey: .title)
            episode = try? c.decode(String.self, forKey: .episode)
            genre = try? c.decode(String.self, forKey: .genre)
            summary = try? c.decode(String.self, forKey: .summary)
            tags = try? c.decode([String].self, forKey: .tags)
        }
    }

    /// Descriptions are clipped: two sentences out never need more than this in.
    static let maxDescriptionCharacters = 600

    static func userMessage(for items: [InputItem]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let json = (try? encoder.encode(["programmes": items])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "Clean up these programmes:\n\(json)"
    }

    /// Accepts `{"programmes":[…]}`, a bare array, or either wrapped in a
    /// Markdown code fence / surrounding prose.
    static func parse(_ content: String) throws -> [OutputItem] {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Trim prose around the JSON value.
        if let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }),
           start < end {
            text = String(text[start...end])
        }
        let data = Data(text.utf8)
        struct Wrapper: Decodable { let programmes: [OutputItem] }
        if let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data) {
            return wrapped.programmes
        }
        do {
            return try JSONDecoder().decode([OutputItem].self, from: data)
        } catch {
            throw OpenRouterClient.ClientError.unreadable("expected a JSON list of programmes")
        }
    }

    /// Validates and clamps one model output. Nil when the title is unusable,
    /// so the raw listing is shown instead.
    static func programme(from output: OutputItem) -> FormattedProgramme? {
        func clean(_ value: String?, max: Int) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
            return String(trimmed.prefix(max))
        }
        guard let title = clean(output.title, max: 120) else { return nil }
        let tags = (output.tags ?? []).filter { allowedTags.contains($0) }
        return FormattedProgramme(
            title: title,
            episode: clean(output.episode, max: 24),
            genre: clean(output.genre, max: 24),
            summary: clean(output.summary, max: 400),
            tags: Array(tags.prefix(3))
        )
    }

    /// Stable cache key for a raw programme's text.
    static func cacheKey(title: String, description: String) -> String {
        let input = "\(version)\u{1F}\(title)\u{1F}\(description)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Formatter

/// AI clean-up of guide text through OpenRouter.
///
/// Views call `request(_:)` for programmes they're about to show and render
/// `display(for:)`, which returns the formatted version once it arrives
/// (this object is `@Observable`, so they update automatically). Requests are
/// coalesced into batches, deduplicated by text, and cached on disk, so a
/// programme is sent at most once. Progress is exposed for the UI.
@MainActor
@Observable
final class EPGFormatter {
    static let shared = EPGFormatter()

    // MARK: Settings

    private enum Keys {
        static let enabled = "epgAI.enabled"
        static let model = "epgAI.model"
        static let keychainService = "io.OpenIPTV.openrouter"
        static let keychainAccount = "apiKey"
    }

    private(set) var isEnabled: Bool
    private(set) var model: String
    /// Last 4 characters of the saved key, for display. Nil when no key.
    private(set) var apiKeyHint: String?

    var hasAPIKey: Bool { apiKeyHint != nil }
    var isActive: Bool { isEnabled && hasAPIKey }

    // MARK: Results + progress

    private(set) var results: [String: FormattedProgramme] = [:]

    /// Counters for the current (or last) run — a run starts when work arrives
    /// while idle and ends when the queue drains.
    private(set) var runTotal = 0
    private(set) var runCompleted = 0
    private(set) var runFailed = 0
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Set after a fatal error, repeated failures or the session cap; cleared
    /// by `resume()` or a settings change.
    private(set) var isPaused = false
    private(set) var sessionTokens = 0
    private(set) var sessionSent = 0

    var runFraction: Double {
        runTotal == 0 ? 0 : Double(runCompleted + runFailed) / Double(runTotal)
    }

    var cachedCount: Int { results.count }

    // MARK: Tuning

    private static let batchSize = 25
    private static let maxConcurrentRequests = 2
    private static let debounce: Duration = .milliseconds(400)
    /// Upper bound on programmes sent per app session — a guard against an
    /// unexpected loop running up the user's OpenRouter bill.
    static let sessionLimit = 1500
    private static let maxCachedEntries = 5000

    // MARK: Queue state (not observed)

    @ObservationIgnored private var pending: [(key: String, listing: EPGListing)] = []
    @ObservationIgnored private var queuedKeys = Set<String>()
    @ObservationIgnored private var failedKeys = Set<String>()
    @ObservationIgnored private var activeRequests = 0
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.enabled)
        model = defaults.string(forKey: Keys.model) ?? OpenRouterClient.defaultModel
        apiKeyHint = Self.readKey().map(Self.hint(for:))
        // Loaded up front (small file) rather than lazily from `display`,
        // which runs during view updates where mutating state is unsafe.
        results = Self.loadCache()
    }

    // MARK: - Public API

    /// Formatted text when available (and the feature is on), raw otherwise.
    func display(for listing: EPGListing) -> EPGDisplay {
        if isEnabled {
            let key = EPGFormatterPrompt.cacheKey(title: listing.title, description: listing.description)
            if let formatted = results[key] {
                return EPGDisplay(
                    title: formatted.title,
                    episode: formatted.episode,
                    genre: formatted.genre,
                    summary: formatted.summary ?? listing.description,
                    tags: formatted.tags,
                    isFormatted: true
                )
            }
        }
        return EPGDisplay(
            title: listing.title,
            episode: nil,
            genre: nil,
            summary: listing.description,
            tags: [],
            isFormatted: false
        )
    }

    /// Queues programmes for formatting. Cheap to call repeatedly: cached,
    /// queued, in-flight and failed programmes are skipped.
    func request(_ listings: [EPGListing]) {
        guard isActive, !isPaused else { return }
        var added = 0
        for listing in listings where !listing.title.isEmpty {
            let key = EPGFormatterPrompt.cacheKey(title: listing.title, description: listing.description)
            guard results[key] == nil, !queuedKeys.contains(key), !failedKeys.contains(key) else { continue }
            queuedKeys.insert(key)
            pending.append((key, listing))
            added += 1
        }
        guard added > 0 else { return }
        if !isRunning {
            runTotal = 0
            runCompleted = 0
            runFailed = 0
        }
        runTotal += added
        isRunning = true
        scheduleFlush()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        if enabled {
            unpause()
        } else {
            cancelQueue()
        }
    }

    func setModel(_ newModel: String) {
        let trimmed = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        model = trimmed.isEmpty ? OpenRouterClient.defaultModel : trimmed
        UserDefaults.standard.set(model, forKey: Keys.model)
        unpause()
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? KeychainHelper.save(Data(trimmed.utf8), service: Keys.keychainService, account: Keys.keychainAccount)
        apiKeyHint = Self.hint(for: trimmed)
        unpause()
    }

    func removeAPIKey() {
        KeychainHelper.delete(service: Keys.keychainService, account: Keys.keychainAccount)
        apiKeyHint = nil
        cancelQueue()
    }

    /// Clears a pause (after the user fixed the cause) and forgets failures so
    /// those programmes are tried again.
    func resume() {
        unpause()
    }

    func clearCache() {
        results = [:]
        failedKeys.removeAll()
        saveTask?.cancel()
        if let url = Self.cacheURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Formats one sample programme and returns the cleaned title. Not cached.
    func testConnection() async throws -> String {
        guard let key = Self.readKey() else { throw OpenRouterClient.ClientError.invalidKey }
        let client = OpenRouterClient(apiKey: key, model: model)
        let sample = EPGFormatterPrompt.InputItem(
            id: "0",
            title: "BBC NEWS AT TEN [HD] (S12E45) *LIVE*",
            description: "THE LATEST NATIONAL AND INTERNATIONAL NEWS, WITH REPORTS FROM BBC CORRESPONDENTS AROUND THE WORLD."
        )
        let (content, usage) = try await client.complete(
            system: EPGFormatterPrompt.system,
            user: EPGFormatterPrompt.userMessage(for: [sample]),
            schema: EPGFormatterPrompt.schema,
            maxTokens: 400
        )
        sessionTokens += usage?.total ?? 0
        guard let output = try EPGFormatterPrompt.parse(content).first,
              let programme = EPGFormatterPrompt.programme(from: output)
        else { throw OpenRouterClient.ClientError.unreadable("no programme returned") }
        return programme.title
    }

    // MARK: - Queue

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self else { return }
            self.flushTask = nil
            self.drain()
        }
    }

    private func drain() {
        while activeRequests < Self.maxConcurrentRequests, !pending.isEmpty, !isPaused, isActive {
            if sessionSent >= Self.sessionLimit {
                pause(String(localized: "Paused after \(Self.sessionLimit) programmes this session to limit cost. Choose Resume to continue."))
                return
            }
            let count = min(Self.batchSize, pending.count, Self.sessionLimit - sessionSent)
            let batch = Array(pending.prefix(count))
            pending.removeFirst(count)
            sessionSent += batch.count
            activeRequests += 1
            Task { [weak self] in
                await self?.send(batch)
                guard let self else { return }
                self.activeRequests -= 1
                self.drain()
                self.updateRunning()
            }
        }
        updateRunning()
    }

    private func send(_ batch: [(key: String, listing: EPGListing)]) async {
        guard let apiKey = Self.readKey() else {
            fail(batch)
            return
        }
        let client = OpenRouterClient(apiKey: apiKey, model: model)
        let items = batch.enumerated().map { index, entry in
            EPGFormatterPrompt.InputItem(
                id: String(index),
                title: entry.listing.title,
                description: String(entry.listing.description.prefix(EPGFormatterPrompt.maxDescriptionCharacters))
            )
        }

        do {
            let (content, usage) = try await client.complete(
                system: EPGFormatterPrompt.system,
                user: EPGFormatterPrompt.userMessage(for: items),
                schema: EPGFormatterPrompt.schema
            )
            sessionTokens += usage?.total ?? 0
            let outputs = try EPGFormatterPrompt.parse(content)
            let byId = Dictionary(outputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            var updated = results
            var completed = 0
            for (index, entry) in batch.enumerated() {
                queuedKeys.remove(entry.key)
                if let output = byId[String(index)], let programme = EPGFormatterPrompt.programme(from: output) {
                    updated[entry.key] = programme
                    completed += 1
                } else {
                    failedKeys.insert(entry.key)
                }
            }
            results = updated
            runCompleted += completed
            runFailed += batch.count - completed
            consecutiveFailures = 0
            lastError = nil
            scheduleSave()
        } catch let error as OpenRouterClient.ClientError {
            switch error {
            case .rateLimited(let retryAfter):
                // Put the batch back and wait before the next drain.
                for entry in batch.reversed() { pending.insert(entry, at: 0) }
                sessionSent -= batch.count
                lastError = error.localizedDescription
                try? await Task.sleep(for: .seconds(min(max(retryAfter ?? 5, 1), 60)))
            default:
                fail(batch)
                if error.isFatal {
                    pause(error.localizedDescription)
                } else {
                    recordFailure(error.localizedDescription)
                }
            }
        } catch {
            fail(batch)
            recordFailure(error.localizedDescription)
        }
    }

    private func fail(_ batch: [(key: String, listing: EPGListing)]) {
        for entry in batch {
            queuedKeys.remove(entry.key)
            failedKeys.insert(entry.key)
        }
        runFailed += batch.count
    }

    private func recordFailure(_ message: String) {
        logger.error("EPG formatting failed: \(message, privacy: .public)")
        lastError = message
        consecutiveFailures += 1
        if consecutiveFailures >= 3 {
            pause(String(localized: "Paused after repeated errors: \(message)"))
        }
    }

    private func pause(_ message: String) {
        isPaused = true
        lastError = message
        cancelQueue(countAsFailed: true)
    }

    private func unpause() {
        isPaused = false
        lastError = nil
        consecutiveFailures = 0
        sessionSent = 0
        failedKeys.removeAll()
    }

    /// Drops queued work. Counted as failed only when an error caused it, not
    /// when the user switched the feature off.
    private func cancelQueue(countAsFailed: Bool = false) {
        flushTask?.cancel()
        flushTask = nil
        if countAsFailed { runFailed += pending.count } else { runTotal -= pending.count }
        for entry in pending { queuedKeys.remove(entry.key) }
        pending.removeAll()
        updateRunning()
    }

    private func updateRunning() {
        let running = !pending.isEmpty || activeRequests > 0
        if isRunning != running { isRunning = running }
    }

    // MARK: - Disk cache

    private struct CacheFile: Codable {
        var version: String
        var entries: [String: FormattedProgramme]
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("EPGFormatCache.json")
    }

    private static func loadCache() -> [String: FormattedProgramme] {
        guard let url = cacheURL,
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(CacheFile.self, from: data),
              file.version == EPGFormatterPrompt.version
        else { return [:] }
        return file.entries
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.trimCacheIfNeeded()
            let file = CacheFile(version: EPGFormatterPrompt.version, entries: self.results)
            guard let url = Self.cacheURL, let data = try? JSONEncoder().encode(file) else { return }
            // Caches can be purged by tvOS at any time; losing it only costs a re-format.
            try? data.write(to: url, options: .atomic)
        }
    }

    private func trimCacheIfNeeded() {
        guard results.count > Self.maxCachedEntries else { return }
        let keep = results.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(Self.maxCachedEntries * 4 / 5)
        results = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    // MARK: - Keychain

    private static func readKey() -> String? {
        guard let data = KeychainHelper.read(service: Keys.keychainService, account: Keys.keychainAccount),
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    private static func hint(for key: String) -> String {
        String(key.suffix(4))
    }
}
