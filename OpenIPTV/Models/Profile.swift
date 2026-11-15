import Foundation
import SwiftData

@Model
final class Profile {
    @Attribute(.unique) var id: String
    var name: String
    var username: String
    var password: String
    var status: String
    var maxConnections: String
    var createdAt: String
    var expiresAt: String
    var isAuth: Bool

    var serverURL: String
    var serverPort: String
    var serverHttpsPort: String
    var serverProtocol: String

    var lastSyncedAt: Date?
    var syncIntervalDays: Int
    var hideAdultContent: Bool
    /// Favourite live channels (stream ids), in the order they were added.
    /// Optional: added in schema 1.7.0 (lightweight migration needs optional).
    var favoriteLiveStreamIds: [Int]? = nil

    @Relationship(deleteRule: .cascade, inverse: \Server.profile) var server: Server?
    @Relationship(deleteRule: .nullify, inverse: \CategoryEntity.profile) var categories: [CategoryEntity] = []

    init(
        id: String = UUID().uuidString,
        name: String? = nil,
        username: String,
        password: String,
        status: String,
        maxConnections: String,
        createdAt: String,
        expiresAt: String,
        isAuth: Bool = true,
        serverURL: String,
        serverPort: String = "",
        serverHttpsPort: String = "",
        serverProtocol: String = "http",
        lastSyncedAt: Date? = nil,
        syncIntervalDays: Int = 7,
        hideAdultContent: Bool = true
    ) {
        self.id = id
        self.name = name ?? username
        self.username = username
        self.password = password
        self.status = status
        self.maxConnections = maxConnections
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.isAuth = isAuth
        self.serverURL = serverURL
        self.serverPort = serverPort
        self.serverHttpsPort = serverHttpsPort
        self.serverProtocol = serverProtocol
        self.lastSyncedAt = lastSyncedAt
        self.syncIntervalDays = syncIntervalDays
        self.hideAdultContent = hideAdultContent
    }

    var isSyncStale: Bool {
        guard syncIntervalDays > 0, syncIntervalDays < Int.max else { return false }
        guard let last = lastSyncedAt else { return true }
        let interval = TimeInterval(syncIntervalDays) * 24 * 60 * 60
        return Date().timeIntervalSince(last) > interval
    }

    /// Mirrors `XtreamAPIService.identity`. Lets `ContentView` verify the
    /// injected repository has been rebuilt for this profile before bootstrap.
    var repositoryIdentity: String { "\(serverURL)|\(username)" }

    // MARK: Favourite channels

    func isFavoriteLive(_ streamId: Int) -> Bool {
        favoriteLiveStreamIds?.contains(streamId) ?? false
    }

    func toggleFavoriteLive(_ streamId: Int) {
        var ids = favoriteLiveStreamIds ?? []
        if let index = ids.firstIndex(of: streamId) {
            ids.remove(at: index)
        } else {
            ids.append(streamId)
        }
        favoriteLiveStreamIds = ids
    }

}

extension Profile {
    private enum KeychainConstants {
        static let service = "io.OpenIPTV.profile.password"
    }

    /// Returns the password from Keychain. If Keychain has no entry but the
    /// legacy SwiftData `password` field is non-empty, migrates it into
    /// Keychain and clears the field on the way out.
    func resolvedPassword() -> String {
        if let data = KeychainHelper.read(service: KeychainConstants.service, account: id),
           let value = String(data: data, encoding: .utf8),
           !value.isEmpty {
            return value
        }
        if !password.isEmpty {
            let legacy = password
            try? KeychainHelper.save(Data(legacy.utf8), service: KeychainConstants.service, account: id)
            password = ""
            return legacy
        }
        return ""
    }

    /// Persists the password into Keychain and clears the legacy SwiftData field.
    func setPassword(_ newValue: String) {
        try? KeychainHelper.save(Data(newValue.utf8), service: KeychainConstants.service, account: id)
        password = ""
    }

    /// Removes the password from Keychain. Call before deleting the Profile.
    func clearPassword() {
        KeychainHelper.delete(service: KeychainConstants.service, account: id)
        password = ""
    }
}

// MARK: - Subscription expiry

extension Profile {
    /// `expiresAt` holds the panel's Unix `exp_date`; empty / "null" / "0"
    /// means the account never expires.
    var expiryDate: Date? {
        guard let seconds = TimeInterval(expiresAt), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Whole days until expiry (negative once expired); nil when unlimited.
    func daysUntilExpiry(from now: Date = .now) -> Int? {
        guard let expiry = expiryDate else { return nil }
        return Int((expiry.timeIntervalSince(now) / 86_400).rounded(.down))
    }

    /// Expired, or expiring within `ProfileExpiry.warningDays`.
    var isExpiringSoon: Bool {
        guard let days = daysUntilExpiry() else { return false }
        return days < ProfileExpiry.warningDays
    }
}

enum ProfileExpiry {
    static let warningDays = 7

    /// "Expires today", "Expires in 3 days", "Expired 2 days ago", "Never expires".
    static func summary(for profile: Profile, now: Date = .now) -> String {
        guard let expiry = profile.expiryDate else { return String(localized: "Never expires") }
        if expiry <= now {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return String(localized: "Expired \(formatter.localizedString(for: expiry, relativeTo: now))")
        }
        let days = profile.daysUntilExpiry(from: now) ?? 0
        switch days {
        case 0: return String(localized: "Expires today")
        case 1: return String(localized: "Expires tomorrow")
        default: return String(localized: "Expires in \(days) days")
        }
    }
}

// MARK: - Parental PIN

/// A per-profile 4-digit PIN guarding "Hide adult content". Kept in the
/// Keychain (like the account password), never in SwiftData.
extension Profile {
    private enum PINKeychain {
        static let service = "io.OpenIPTV.profile.parentalPIN"
    }

    static let parentalPINLength = 4

    var hasParentalPIN: Bool {
        KeychainHelper.read(service: PINKeychain.service, account: id) != nil
    }

    func verifyParentalPIN(_ candidate: String) -> Bool {
        guard let data = KeychainHelper.read(service: PINKeychain.service, account: id),
              let stored = String(data: data, encoding: .utf8)
        else { return false }
        return stored == candidate
    }

    func setParentalPIN(_ pin: String) {
        try? KeychainHelper.save(Data(pin.utf8), service: PINKeychain.service, account: id)
    }

    func clearParentalPIN() {
        KeychainHelper.delete(service: PINKeychain.service, account: id)
    }
}

@Model
final class Server {
    var url: String
    var port: String
    var httpsPort: String
    var serverProtocol: String

    var profile: Profile?

    init(url: String, port: String, httpsPort: String, serverProtocol: String, account: Profile? = nil) {
        self.url = url
        self.port = port
        self.httpsPort = httpsPort
        self.serverProtocol = serverProtocol
        self.profile = account
    }
}
