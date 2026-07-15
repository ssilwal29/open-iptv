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
    let isAuthenticated: Bool = false
    let createdAt: String
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
}
