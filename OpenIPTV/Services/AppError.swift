import Foundation

enum AppError: LocalizedError {
    case invalidURL
    case invalidResponse(statusCode: Int)
    case decodingFailed(Error)
    case credentialsMissing
    case authenticationFailed
    case networkUnavailable
    case retriesExhausted(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL is invalid. Please check your settings."
        case .invalidResponse(let code):
            return "The server returned an unexpected response (HTTP \(code))."
        case .decodingFailed(let error):
            return "Couldn't read the server's data — \(Self.decodeReason(error)). The response may be in an unexpected format."
        case .credentialsMissing:
            return "No account configured. Please set up your IPTV account first."
        case .authenticationFailed:
            return "The server rejected that username or password."
        case .networkUnavailable:
            return "No internet connection. Reconnect and try again."
        case .retriesExhausted(let underlying):
            return "Server unreachable after several attempts: \(underlying.localizedDescription)"
        }
    }

    /// Concise, human-readable reason from a `DecodingError` so a malformed
    /// response names the offending field/type instead of a generic message.
    private static func decodeReason(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        switch error {
        case .typeMismatch(let type, let ctx):
            return "unexpected type for '\(ctx.codingPath.last?.stringValue ?? "?")' (expected \(type))"
        case .keyNotFound(let key, _):
            return "missing field '\(key.stringValue)'"
        case .valueNotFound(_, let ctx):
            return "null value for '\(ctx.codingPath.last?.stringValue ?? "?")'"
        case .dataCorrupted(let ctx):
            return ctx.debugDescription
        @unknown default:
            return "decoding error"
        }
    }
}
