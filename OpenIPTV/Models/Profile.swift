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
