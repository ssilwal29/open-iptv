import Foundation
import SwiftData

/// Coalesces SwiftData saves so a burst of toggles (favorite, watch later,
/// settings switches) doesn't pay the per-save journal cost on every tap.
///
/// `modelContext.save()` runs synchronously on the main actor and journals
/// the entire dirty graph; doing it once per remote-button press is enough
/// to cause perceptible input lag on tvOS. We instead schedule a single save
/// after a short debounce window — rapid taps cancel and reschedule, so the
/// store ultimately ends up consistent without blocking the UI thread on
/// each individual mutation.
@MainActor
enum DeferredSave {
    private static var pending: Task<Void, Never>?

    static func schedule(_ context: ModelContext, delay: Duration = .milliseconds(500)) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            try? context.save()
        }
    }
}
