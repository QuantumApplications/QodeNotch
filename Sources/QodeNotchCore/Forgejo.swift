import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Logins stored by forgejo-cli (`fj auth login` / `fj auth add-key`).
/// The CLI has no machine-readable output, so QodeNotch reuses its token and
/// talks to the Forgejo REST API directly.
public enum FjCredentials {
    /// keys.json locations used by forgejo-cli (current and pre-0.4 "Cyborus" path).
    static var keyFiles: [String] {
        let home = Paths.home
        var files = [
            home + "/Library/Application Support/forgejo-cli.forgejo-cli/keys.json",
            home + "/Library/Application Support/Cyborus.forgejo-cli/keys.json",
        ]
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
        files += [xdg + "/forgejo-cli/keys.json"]
        return files
    }

    /// host (e.g. "codeberg.org" or "git.example.com:3000") → token
    public static func logins() -> [String: String] {
        for file in keyFiles {
            guard let data = FileManager.default.contents(atPath: file) else { continue }
            if let parsed = parse(data), !parsed.isEmpty { return parsed }
        }
        return [:]
    }

    public static func parse(_ data: Data) -> [String: String]? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hosts = obj["hosts"] as? [String: Any] else { return nil }
        var result: [String: String] = [:]
        for (host, info) in hosts {
            if let login = info as? [String: Any], let token = login["token"] as? String, !token.isEmpty {
                result[host.lowercased()] = token
            }
        }
        return result
    }

    public static func token(forHost host: String) -> String? {
        let all = logins()
        let h = host.lowercased()
        return all[h] ?? all.first { $0.key.hasPrefix(h + "/") || $0.key.hasPrefix(h + ":") }?.value
    }

    public static func knows(host: String) -> Bool { token(forHost: host) != nil }
}

/// Minimal Forgejo (and Gitea-compatible) API client for PR status.
public enum ForgejoAPI {
    public struct Repo: Equatable, Sendable {
        public var host: String
        public var owner: String
        public var name: String
        public var apiBase: String { "https://\(host)/api/v1/repos/\(owner)/\(name)" }
    }

    /// owner/repo from a git remote (https or ssh form).
    public static func repo(fromRemote remote: String) -> Repo? {
        guard let host = PullRequestService.remoteHost(remote) else { return nil }
        var path = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let space = path.lastIndex(of: " ") { path = String(path[path.index(after: space)...]) }
        if let scheme = path.range(of: "://") { path = String(path[scheme.upperBound...]) }
        if let at = path.firstIndex(of: "@") { path = String(path[path.index(after: at)...]) }
        // Drop host (and ssh port / scp-style colon).
        guard let sep = path.firstIndex(where: { $0 == "/" || $0 == ":" }) else { return nil }
        path = String(path[path.index(after: sep)...])
        if let first = path.split(separator: "/").first, Int(first) != nil { path = path.split(separator: "/").dropFirst().joined(separator: "/") }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return Repo(host: host, owner: parts[parts.count - 2], name: parts[parts.count - 1])
    }

    /// Repo + number from a PR web URL: https://host/owner/repo/pulls/12
    public static func pull(fromURL url: String) -> (repo: Repo, number: Int)? {
        guard let u = URL(string: url), let host = u.host else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(of: "pulls"), i >= 2, i + 1 < parts.count, let n = Int(parts[i + 1]) else { return nil }
        let hostWithPort = u.port.map { "\(host):\($0)" } ?? host
        return (Repo(host: hostWithPort, owner: parts[i - 2], name: parts[i - 1]), n)
    }

    static func get(_ url: String, host: String) async -> Any? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QodeNotch", forHTTPHeaderField: "User-Agent")
        if let token = FjCredentials.token(forHost: host) {
            req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        guard let (data, response) = try? await URLSession(configuration: config).data(for: req),
              let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    public static func prURL(repo: Repo, branch: String) async -> String? {
        guard let list = await get("\(repo.apiBase)/pulls?state=all&sort=recentupdate&limit=50", host: repo.host) as? [[String: Any]] else { return nil }
        return matchPR(list, branch: branch)
    }

    static func matchPR(_ list: [[String: Any]], branch: String) -> String? {
        let match = list.filter { (($0["head"] as? [String: Any])?["ref"] as? String) == branch }
            .max { ($0["number"] as? Int ?? 0) < ($1["number"] as? Int ?? 0) }
        return match?["html_url"] as? String
    }

    public static func status(url: String) async -> PrStatus? {
        guard let (repo, n) = pull(fromURL: url),
              let pr = await get("\(repo.apiBase)/pulls/\(n)", host: repo.host) as? [String: Any] else { return nil }
        let sha = (pr["head"] as? [String: Any])?["sha"] as? String
        async let reviewsT = get("\(repo.apiBase)/pulls/\(n)/reviews", host: repo.host)
        var combined: Any?
        if let sha { combined = await get("\(repo.apiBase)/commits/\(sha)/status", host: repo.host) }
        let reviews = await reviewsT
        return parseStatus(pr: pr, combined: combined as? [String: Any], reviews: reviews as? [[String: Any]], fallbackUrl: url)
    }

    public static func parseStatus(pr: [String: Any], combined: [String: Any]?, reviews: [[String: Any]]?, fallbackUrl: String) -> PrStatus {
        let merged = pr["merged"] as? Bool ?? false
        let state = merged ? "MERGED" : ((pr["state"] as? String) == "closed" ? "CLOSED" : "OPEN")
        let statuses = combined?["statuses"] as? [[String: Any]] ?? []
        var passing = 0, failing = 0, pending = 0
        for s in statuses {
            switch (s["status"] as? String) ?? (s["state"] as? String) ?? "" {
            case "success", "skipped": passing += 1
            case "failure", "error": failing += 1
            default: pending += 1
            }
        }
        let checks: PrChecks = statuses.isEmpty ? .none : failing > 0 ? .failing : pending > 0 ? .pending : .passing
        // Latest review per reviewer decides.
        var latest: [String: String] = [:]
        for r in reviews ?? [] where (r["dismissed"] as? Bool) != true {
            let user = ((r["user"] as? [String: Any])?["login"] as? String) ?? UUID().uuidString
            if let st = r["state"] as? String, st != "COMMENT", st != "PENDING" { latest[user] = st }
        }
        let review: String? = latest.values.contains("REQUEST_CHANGES") ? "CHANGES_REQUESTED"
            : latest.values.contains("APPROVED") ? "APPROVED" : nil
        let mergeable = pr["mergeable"] as? Bool
        return PrStatus(url: pr["html_url"] as? String ?? fallbackUrl, state: state, checks: checks, reviewDecision: review,
                        mergeable: mergeable == false && state == "OPEN" ? "CONFLICTING" : "MERGEABLE",
                        mergeStateStatus: "UNKNOWN", checksTotal: statuses.count, checksPassing: passing,
                        checksFailing: failing, checksPending: pending, unresolvedThreads: 0,
                        commentCount: pr["comments"] as? Int ?? 0)
    }
}
