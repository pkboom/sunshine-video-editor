import Foundation

/// Single-video YouTube link gate. Anything that isn't one video (playlist, channel, no id) is rejected.
public enum YouTubeURL {
    private static let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]
    private static let idPathPrefixes: Set<String> = ["shorts", "live", "embed"]

    /// The 11-character video id, or nil.
    public static func videoID(from s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let c = URLComponents(string: withScheme),
              let scheme = c.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = c.host?.lowercased() else { return nil }
        let parts = c.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        let candidate: String?
        if host == "youtu.be" {
            candidate = parts.count == 1 ? parts[0] : nil
        } else if hosts.contains(host) {
            if parts == ["watch"] {
                candidate = c.queryItems?.first(where: { $0.name == "v" })?.value
            } else if parts.count == 2, idPathPrefixes.contains(parts[0]) {
                candidate = parts[1]
            } else {
                candidate = nil
            }
        } else {
            candidate = nil
        }
        guard let id = candidate, isValidID(id) else { return nil }
        return id
    }

    /// `https://www.youtube.com/watch?v=<id>` (no playlist or other parameters).
    public static func canonicalURL(id: String) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "www.youtube.com"
        c.path = "/watch"
        c.queryItems = [URLQueryItem(name: "v", value: id)]
        return c.url!
    }

    static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D || b == 0x5F
        }
    }
}
