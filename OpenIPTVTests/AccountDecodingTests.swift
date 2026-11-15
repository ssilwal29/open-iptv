import Foundation
import Testing
@testable import OpenIPTV

@Suite("Account decoding")
struct AccountDecodingTests {
    private func decode(_ json: String) throws -> Account {
        try JSONDecoder().decode(Account.self, from: Data(json.utf8))
    }

    @Test func acceptsNullExpiryAndNumericFields() throws {
        let account = try decode("""
        {"user_info":{"username":"u","password":"p","status":"Active","max_connections":2,
        "auth":1,"created_at":"1700000000","exp_date":null},
        "server_info":{"url":"example.com","port":8080,"https_port":"443","server_protocol":"http"}}
        """)
        #expect(account.info.isAuthenticated)
        #expect(account.info.expiresAt.isEmpty)
        #expect(account.info.maxConnections == "2")
        #expect(account.serverInfo.port == "8080")
    }

    @Test func readsBooleanAuthFlag() throws {
        let account = try decode("""
        {"user_info":{"username":"u","password":"p","status":"Active","auth":true,"exp_date":"1800000000"},
        "server_info":{}}
        """)
        #expect(account.info.isAuthenticated)
        #expect(account.info.expiresAt == "1800000000")
        #expect(account.serverInfo.serverProtocol == "http")
    }

    @Test func rejectedLoginDecodesAsUnauthenticated() throws {
        let account = try decode(#"{"user_info":{"auth":0},"server_info":{}}"#)
        #expect(!account.info.isAuthenticated)
    }
}
