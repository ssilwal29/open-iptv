import Foundation

struct SyncStats: Sendable, Equatable {
    var moviesInserted: Int = 0
    var moviesUpdated: Int = 0
    var seriesInserted: Int = 0
    var seriesUpdated: Int = 0
    var livesInserted: Int = 0
    var livesUpdated: Int = 0
    var categoriesInserted: Int = 0
    var categoriesUpdated: Int = 0
    var pruned: Int = 0
    var startedAt: Date = .now
    var finishedAt: Date?

    var totalMovies: Int { moviesInserted + moviesUpdated }
    var totalSeries: Int { seriesInserted + seriesUpdated }
    var totalLives: Int { livesInserted + livesUpdated }

    var duration: TimeInterval? {
        guard let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

enum SyncProgress: Sendable, Equatable {
    case idle
    case fetching
    case writing(kind: ContentKind, completed: Int, total: Int)
    case pruning
    case done(SyncStats)
    case failed(String)
}

enum SyncStep: Sendable, Equatable {
    case initializing
    case movies
    case series
    case live
    case finishing

    var iconName: String {
        switch self {
        case .initializing: "arrow.down.circle"
        case .movies:       "movieclapper"
        case .series:       "popcorn"
        case .live:         "tv.badge.wifi"
        case .finishing:    "sparkles"
        }
    }

    var title: String {
        switch self {
        case .initializing: String(localized: "Preparing your library…")
        case .movies:       String(localized: "Loading movies…")
        case .series:       String(localized: "Loading series…")
        case .live:         String(localized: "Loading live channels…")
        case .finishing:    String(localized: "Wrapping up…")
        }
    }

    /// Each step owns a fixed band of the global 0…1 progress bar. Ordered to
    /// match the sync's actual write order (Live first, then Movies, then
    /// Series) so the bar advances monotonically instead of jumping backward.
    var band: ClosedRange<Double> {
        switch self {
        case .initializing: 0.00...0.05
        case .live:         0.05...0.35
        case .movies:       0.35...0.65
        case .series:       0.65...0.95
        case .finishing:    0.95...1.00
        }
    }
}

extension SyncProgress {
    /// Whether the sync banner should be visible — the whole run (fetching →
    /// writing → pruning) plus the brief `.done` confirmation. `.idle`/`.failed`
    /// hide it.
    var isActive: Bool {
        switch self {
        case .fetching, .writing, .pruning, .done: return true
        case .idle, .failed: return false
        }
    }

    /// The current high-level step. `.failed` reports `.initializing` so the
    /// failure UI doesn't depend on prior step state.
    var step: SyncStep {
        switch self {
        case .idle, .fetching, .failed:
            return .initializing
        case .writing(let kind, _, _):
            switch kind {
            case .movie: return .movies
            case .serie: return .series
            case .live:  return .live
            }
        case .pruning, .done:
            return .finishing
        }
    }

    /// Phase-weighted global progress in `0…1`. Inside a writing step the
    /// fraction interpolates by `completed / total`; when `total <= 0` the
    /// step's start anchor is used.
    var globalFraction: Double {
        switch self {
        case .idle, .failed:
            return SyncStep.initializing.band.lowerBound
        case .fetching:
            return SyncStep.initializing.band.upperBound
        case .writing(_, let completed, let total):
            let band = step.band
            let ratio = total > 0 ? min(1, Double(completed) / Double(total)) : 0
            return band.lowerBound + (band.upperBound - band.lowerBound) * ratio
        case .pruning:
            return SyncStep.finishing.band.lowerBound
        case .done:
            return SyncStep.finishing.band.upperBound
        }
    }
}
