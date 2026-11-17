import Foundation

public enum GitInfo {
    static func git(_ args: [String], cwd: String, timeout: TimeInterval = 3) async -> String {
        let r = await Shell.run("git", args, cwd: cwd, timeout: timeout)
        return r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    public static func summary(cwd: String) async -> GitSummary? {
        async let branchT = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd)
        async let porcelainT = git(["status", "--porcelain"], cwd: cwd)
        async let statT = git(["diff", "HEAD", "--shortstat"], cwd: cwd)
        let (branch, porcelain, stat) = await (branchT, porcelainT, statT)
        guard !branch.isEmpty else { return nil }
        return parseSummary(branch: branch, porcelain: porcelain, shortStat: stat)
    }

    public static func parseSummary(branch: String, porcelain: String, shortStat: String) -> GitSummary {
        let lines = porcelain.split(separator: "\n")
        let untracked = lines.filter { $0.hasPrefix("??") }.count
        func number(before word: String) -> Int {
            guard let r = shortStat.range(of: "(\\d+) \(word)", options: .regularExpression) else { return 0 }
            return Int(shortStat[r].split(separator: " ").first ?? "0") ?? 0
        }
        return GitSummary(branch: branch, changedFiles: lines.count - untracked, additions: number(before: "insertion"),
                          deletions: number(before: "deletion"), untrackedFiles: untracked,
                          shortStat: shortStat.isEmpty ? "clean" : shortStat)
    }

    public static func diffStat(cwd: String) async -> String? {
        let s = await git(["diff", "HEAD", "--stat"], cwd: cwd, timeout: 5)
        return s.isEmpty ? nil : s
    }

    /// Path of the main worktree (first entry of `git worktree list`).
    public static func mainWorktree(cwd: String) async -> String? {
        let out = await git(["worktree", "list", "--porcelain"], cwd: cwd)
        for line in out.split(separator: "\n") where line.hasPrefix("worktree ") {
            return String(line.dropFirst("worktree ".count))
        }
        return nil
    }

    public static func localBranches(repo: String) async -> [String] {
        let out = await git(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)", "refs/heads"], cwd: repo, timeout: 5)
        return out.split(separator: "\n").map(String.init)
    }

    public static func isRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/.git")
    }
}

/// GitHub PR lookups via the `gh` CLI, with small TTL caches.
public actor PullRequestService {
    public static let shared = PullRequestService()

    private var urlCache: [String: (url: String?, at: Date)] = [:]
    private var statusCache: [String: (status: PrStatus, at: Date)] = [:]

    public func prUrl(cwd: String, branch: String) async -> String? {
        let key = cwd + "::" + branch
        if let c = urlCache[key], Date().timeIntervalSince(c.at) < (c.url == nil ? 30 : 60) { return c.url }
        // `gh pr list --head` avoids treating numeric branch names as PR numbers.
        let r = await Shell.run("gh", ["pr", "list", "--head", branch, "--state", "all", "--limit", "1", "--json", "url", "--jq", ".[0].url"], cwd: cwd, timeout: 8)
        let url = r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let value: String? = url.isEmpty ? nil : url
        urlCache[key] = (value, Date())
        return value
    }

    public func status(url: String, cwd: String) async -> PrStatus? {
        if let c = statusCache[url], Date().timeIntervalSince(c.at) < 30 { return c.status }
        async let viewT = Shell.run("gh", ["pr", "view", url, "--json", "url,state,statusCheckRollup,reviewDecision,mergeable,mergeStateStatus"], cwd: cwd, timeout: 10)
        async let threadsT = reviewThreads(url: url, cwd: cwd)
        let (view, threads) = await (viewT, threadsT)
        guard view.ok, let status = Self.parseStatus(view.stdout, fallbackUrl: url) else { return nil }
        var s = status
        s.unresolvedThreads = threads.unresolved
        s.commentCount = threads.comments
        statusCache[url] = (s, Date())
        return s
    }

    public func invalidate() {
        urlCache.removeAll()
        statusCache.removeAll()
    }

    public static func parseStatus(_ json: String, fallbackUrl: String) -> PrStatus? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let rollup = obj["statusCheckRollup"] as? [[String: Any]] ?? []
        var passing = 0, failing = 0, pending = 0
        for c in rollup {
            let conclusion = c["conclusion"] as? String ?? ""
            let state = c["state"] as? String ?? ""
            if ["SUCCESS", "SKIPPED", "NEUTRAL"].contains(conclusion) || state == "SUCCESS" {
                passing += 1
            } else if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) || state == "FAILURE" || state == "ERROR" {
                failing += 1
            } else {
                pending += 1
            }
        }
        let checks: PrChecks = rollup.isEmpty ? .none : failing > 0 ? .failing : pending > 0 ? .pending : .passing
        let review = (obj["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return PrStatus(url: obj["url"] as? String ?? fallbackUrl, state: obj["state"] as? String ?? "OPEN", checks: checks,
                        reviewDecision: review, mergeable: obj["mergeable"] as? String ?? "UNKNOWN",
                        mergeStateStatus: obj["mergeStateStatus"] as? String ?? "UNKNOWN", checksTotal: rollup.count,
                        checksPassing: passing, checksFailing: failing, checksPending: pending)
    }

    static func parsePrUrl(_ url: String) -> (owner: String, repo: String, number: Int)? {
        let parts = url.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(where: { $0.contains("github") }), parts.count > i + 4,
              parts[i + 3] == "pull", let n = Int(parts[i + 4]) else { return nil }
        return (parts[i + 1], parts[i + 2], n)
    }

    private func reviewThreads(url: String, cwd: String) async -> (unresolved: Int, comments: Int) {
        guard let p = Self.parsePrUrl(url) else { return (0, 0) }
        let query = """
        query($owner:String!,$repo:String!,$num:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$num){reviewThreads(first:100){nodes{isResolved}} comments{totalCount}}}}
        """
        let r = await Shell.run("gh", ["api", "graphql", "-f", "query=\(query)", "-F", "owner=\(p.owner)", "-F", "repo=\(p.repo)", "-F", "num=\(p.number)"], cwd: cwd, timeout: 10)
        guard r.ok, let data = r.stdout.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pr = ((obj["data"] as? [String: Any])?["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] else { return (0, 0) }
        let nodes = (pr["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let unresolved = nodes.filter { ($0["isResolved"] as? Bool) == false }.count
        let comments = (pr["comments"] as? [String: Any])?["totalCount"] as? Int ?? 0
        return (unresolved, comments)
    }
}
