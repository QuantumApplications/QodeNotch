import Foundation

/// Finds pull/merge request URLs (GitHub, GitLab incl. self-hosted, Forgejo/Gitea)
/// mentioned anywhere in a session – e.g. the URL `glab mr create` printed.
public enum PRLinkExtractor {
    static let patterns: [NSRegularExpression] = [
        // GitLab: https://host/group/sub/project/-/merge_requests/12
        #"https?://[A-Za-z0-9.\-:]+(?:/[A-Za-z0-9._\-~%]+)+/-/merge_requests/\d+"#,
        // GitHub: https://github.com/owner/repo/pull/12
        #"https?://github\.com/[A-Za-z0-9._\-]+/[A-Za-z0-9._\-]+/pull/\d+"#,
        // Forgejo / Gitea / Codeberg: https://host/owner/repo/pulls/12
        #"https?://[A-Za-z0-9.\-:]+/[A-Za-z0-9._\-]+/[A-Za-z0-9._\-]+/pulls/\d+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// URLs in order of appearance (duplicates removed, last mention wins the position).
    public static func urls(in text: String) -> [String] {
        var found: [(String, Int)] = []
        let range = NSRange(text.startIndex..., in: text)
        for re in patterns {
            for m in re.matches(in: text, range: range) {
                guard let r = Range(m.range, in: text) else { continue }
                found.append((String(text[r]), m.range.location))
            }
        }
        var order: [String] = []
        for (url, _) in found.sorted(by: { $0.1 < $1.1 }) {
            order.removeAll { $0 == url }
            order.append(url)
        }
        return order
    }
}

/// PR/MR links per transcript, read incrementally like `SessionTitles`.
public actor SessionPRLinks {
    public static let shared = SessionPRLinks()

    private struct State {
        var offset: UInt64 = 0
        var urls: [String] = []
    }
    private var files: [String: State] = [:]

    public init() {}

    /// Newest mention first, at most `limit`.
    public func links(transcript path: String, limit: Int = 6) -> [String] {
        var state = files[path] ?? State()
        if let fh = FileHandle(forReadingAtPath: path) {
            defer { try? fh.close() }
            let size = (try? fh.seekToEnd()) ?? 0
            if size < state.offset { state = State() }
            if size > state.offset {
                try? fh.seek(toOffset: state.offset)
                let data = fh.readDataToEndOfFile()
                if let last = data.lastIndex(of: 0x0A) {
                    let complete = data[data.startIndex...last]
                    state.offset += UInt64(complete.count)
                    // JSON strings may escape slashes; undo that before matching.
                    let text = String(decoding: complete, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
                    for url in PRLinkExtractor.urls(in: text) {
                        state.urls.removeAll { $0 == url }
                        state.urls.append(url)
                    }
                    if state.urls.count > 30 { state.urls = Array(state.urls.suffix(30)) }
                }
            }
        }
        files[path] = state
        if files.count > 500 { files = files.filter { $0.key == path } }
        return Array(state.urls.reversed().prefix(limit))
    }
}
