import Foundation

struct Account: Codable {
    let info: AccountInfo
    let serverInfo: ServerInfo
    
    enum CodingKeys: String, CodingKey {
        case info = "user_info"
        case serverInfo = "server_info"
    }
}

struct AccountInfo: Codable {
    let username: String
    let password: String
    let status: String
    let maxConnections: String
    let isAuthenticated: Bool
    let createdAt: String
    /// Unix timestamp as a string; empty for accounts with no expiry
    /// (panels send `null` for those).
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case username
        case password
        case status
        case maxConnections = "max_connections"
        case isAuthenticated = "auth"
        case createdAt = "created_at"
        case expiresAt = "exp_date"
    }

    // Lenient: panels disagree on whether these are strings, ints or null,
    // and a strict decode turns a valid login into a "can't read data" error.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        username = c.flexibleString(.username)
        password = c.flexibleString(.password)
        status = c.flexibleString(.status)
        maxConnections = c.flexibleString(.maxConnections)
        if let flag = try? c.decode(Bool.self, forKey: .isAuthenticated) {
            isAuthenticated = flag
        } else {
            isAuthenticated = c.flexibleInt(.isAuthenticated) == 1
        }
        createdAt = c.flexibleString(.createdAt)
        expiresAt = c.flexibleString(.expiresAt)
    }
}

struct ServerInfo: Codable {
    let url: String
    let port: String
    let httpsPort: String
    let serverProtocol: String
    
    enum CodingKeys: String, CodingKey {
        case url
        case port
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.flexibleString(.url)
        port = c.flexibleString(.port)
        httpsPort = c.flexibleString(.httpsPort)
        serverProtocol = c.flexibleString(.serverProtocol, default: "http")
    }
}
