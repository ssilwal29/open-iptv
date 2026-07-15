import Foundation

extension URL {
    /// Returns a copy of the URL with `http` rewritten to `https`.
    /// Xtream providers commonly serve images/streams over HTTP but also accept HTTPS;
    /// forcing HTTPS at load-time avoids ATS blocking insecure loads.
    var secure: URL {
        guard scheme == "http",
              var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.scheme = "https"
        // Strip HTTP ports so HTTPS can default to 443. Keep non-default ports as-is.
        if components.port == 80 || components.port == 8080 {
            components.port = nil
        }
        return components.url ?? self
    }
}

extension String {
    /// Convenience: parse a string to a URL, then upgrade to HTTPS.
    var secureURL: URL? {
        URL(string: self)?.secure
    }
}
