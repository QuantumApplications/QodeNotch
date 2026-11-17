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
    private var forgeCache: [String: Forge] = [:]
    private var preference: ForgePreference = .auto

    public enum Forge: String, Sendable { case github, gitlab, forgejo }

    public func setPreference(_ p: ForgePreference) {
        guard p != preference else { return }
        preference = p
        forgeCache.removeAll()
        urlCache.removeAll()
    }

    /// GitHub (gh) or GitLab (glab) for a repository, from the preference or its remote.
    public func forge(cwd: String) async -> Forge {
        switch preference {
        case .github: return .github
        case .gitlab: return .gitlab
        case .forgejo: return .forgejo
        case .auto: break
        }
        if let f = forgeCache[cwd] { return f }
        let remote = await GitInfo.git(["remote", "get-url", "origin"], cwd: cwd)
        let fallback = remote.isEmpty ? await GitInfo.git(["config", "--get-regexp", "^remote\\..*\\.url$"], cwd: cwd) : remote
        let f = await Self.detectForge(remote: fallback)
        forgeCache[cwd] = f
        return f
    }

    static func remoteHost(_ remote: String) -> String? {
        // https://host/owner/repo(.git), git@host:owner/repo.git, ssh://git@host:port/owner/repo
        var r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if let space = r.lastIndex(of: " ") { r = String(r[r.index(after: space)...]) }
        if let scheme = r.range(of: "://") { r = String(r[scheme.upperBound...]) }
        if let at = r.firstIndex(of: "@") { r = String(r[r.index(after: at)...]) }
        let host = r.split(whereSeparator: { $0 == "/" || $0 == ":" }).first.map(String.init)
        return host?.isEmpty == false ? host?.lowercased() : nil
    }

    static func detectForge(remote: String) async -> Forge {
        guard let host = remoteHost(remote) else { return .github }
        if host.contains("github") { return .github }
        if host.contains("gitlab") { return .gitlab }
        if host.contains("codeberg") || host.contains("forgejo") || host.contains("gitea") || FjCredentials.knows(host: host) {
            return .forgejo
        }
        // Self-hosted GitLab without "gitlab" in the name: ask glab whether it knows the host.
        if Shell.which("glab") != nil, await Shell.run("glab", ["auth", "status", "--hostname", host], timeout: 5).ok {
            return .gitlab
        }
        return .github
    }

    public static func isMergeRequestURL(_ url: String) -> Bool { url.contains("/merge_requests/") }
    /// Forgejo/Gitea PR URLs use `/pulls/<n>` (GitHub: `/pull/<n>`).
    public static func isForgejoURL(_ url: String) -> Bool { url.contains("/pulls/") }

    public func prUrl(cwd: String, branch: String) async -> String? {
        let key = cwd + "::" + branch
        if let c = urlCache[key], Date().timeIntervalSince(c.at) < (c.url == nil ? 30 : 60) { return c.url }
        let value: String?
        switch await forge(cwd: cwd) {
        case .github:
            // `gh pr list --head` avoids treating numeric branch names as PR numbers.
            let r = await Shell.run("gh", ["pr", "list", "--head", branch, "--state", "all", "--limit", "1", "--json", "url", "--jq", ".[0].url"], cwd: cwd, timeout: 8)
            let url = r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            value = url.isEmpty ? nil : url
        case .gitlab:
            let r = await Shell.run("glab", ["mr", "list", "--source-branch", branch, "--all", "--per-page", "5", "--output", "json"], cwd: cwd, timeout: 10)
            value = r.ok ? Self.parseGitLabMRList(r.stdout) : nil
        case .forgejo:
            let remote = await GitInfo.git(["remote", "get-url", "origin"], cwd: cwd)
            if let repo = ForgejoAPI.repo(fromRemote: remote) {
                value = await ForgejoAPI.prURL(repo: repo, branch: branch)
            } else {
                value = nil
            }
        }
        urlCache[key] = (value, Date())
        return value
    }

    /// Web URL of the newest MR in `glab mr list --output json`.
    static func parseGitLabMRList(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let sorted = list.sorted { ($0["iid"] as? Int ?? 0) > ($1["iid"] as? Int ?? 0) }
        return sorted.first?["web_url"] as? String
    }

    public func status(url: String, cwd: String) async -> PrStatus? {
        if let c = statusCache[url], Date().timeIntervalSince(c.at) < 30 { return c.status }
        let result: PrStatus?
        if Self.isMergeRequestURL(url) {
            result = await gitLabStatus(url: url, cwd: cwd)
        } else if Self.isForgejoURL(url) {
            result = await ForgejoAPI.status(url: url)
        } else {
            async let viewT = Shell.run("gh", ["pr", "view", url, "--json", "url,state,statusCheckRollup,reviewDecision,mergeable,mergeStateStatus"], cwd: cwd, timeout: 10)
            async let threadsT = reviewThreads(url: url, cwd: cwd)
            let (view, threads) = await (viewT, threadsT)
            if view.ok, var s = Self.parseStatus(view.stdout, fallbackUrl: url) {
                s.unresolvedThreads = threads.unresolved
                s.commentCount = threads.comments
                result = s
            } else {
                result = nil
            }
        }
        if let result { statusCache[url] = (result, Date()) }
        return result
    }

    // MARK: GitLab

    private func gitLabStatus(url: String, cwd: String) async -> PrStatus? {
        guard let iid = url.split(separator: "/").last.map(String.init), Int(iid) != nil else { return nil }
        async let viewT = Shell.run("glab", ["mr", "view", iid, "--output", "json"], cwd: cwd, timeout: 10)
        async let approvalsT = Shell.run("glab", ["api", "projects/:id/merge_requests/\(iid)/approvals"], cwd: cwd, timeout: 10)
        async let discussionsT = Shell.run("glab", ["api", "projects/:id/merge_requests/\(iid)/discussions?per_page=100"], cwd: cwd, timeout: 10)
        let (view, approvals, discussions) = await (viewT, approvalsT, discussionsT)
        guard view.ok else { return nil }
        return Self.parseGitLabStatus(view: view.stdout, approvals: approvals.ok ? approvals.stdout : nil,
                                      discussions: discussions.ok ? discussions.stdout : nil, fallbackUrl: url)
    }

    /// Map `glab mr view --output json` (+ approvals/discussions API) onto PrStatus.
    public static func parseGitLabStatus(view: String, approvals: String?, discussions: String?, fallbackUrl: String) -> PrStatus? {
        guard let data = view.data(using: .utf8),
              let mr = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let state: String
        switch (mr["state"] as? String ?? "").lowercased() {
        case "merged": state = "MERGED"
        case "closed": state = "CLOSED"
        default: state = "OPEN"
        }
        let pipeline = (mr["head_pipeline"] as? [String: Any]) ?? (mr["pipeline"] as? [String: Any])
        let checks: PrChecks
        switch (pipeline?["status"] as? String ?? "").lowercased() {
        case "success": checks = .passing
        case "failed", "canceled", "cancelled": checks = .failing
        case "": checks = .none
        case "skipped", "manual": checks = .passing
        default: checks = .pending   // running, pending, created, preparing, scheduled …
        }
        let conflicts = mr["has_conflicts"] as? Bool ?? false
        var review: String?
        if let a = approvals?.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any] {
            if obj["approved"] as? Bool == true { review = "APPROVED" }
            else if (obj["approvals_left"] as? Int ?? 0) > 0 { review = "REVIEW_REQUIRED" }
        }
        var unresolved = 0
        var comments = mr["user_notes_count"] as? Int ?? 0
        if let d = discussions?.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
            for disc in list {
                let notes = disc["notes"] as? [[String: Any]] ?? []
                if notes.contains(where: { ($0["resolvable"] as? Bool) == true && ($0["resolved"] as? Bool) == false }) { unresolved += 1 }
            }
            if comments == 0 { comments = list.count }
        }
        let checkCount = checks == .none ? 0 : 1
        return PrStatus(url: mr["web_url"] as? String ?? fallbackUrl, state: state, checks: checks, reviewDecision: review,
                        mergeable: conflicts ? "CONFLICTING" : "MERGEABLE",
                        mergeStateStatus: mr["detailed_merge_status"] as? String ?? "UNKNOWN",
                        checksTotal: checkCount, checksPassing: checks == .passing ? 1 : 0,
                        checksFailing: checks == .failing ? 1 : 0, checksPending: checks == .pending ? 1 : 0,
                        unresolvedThreads: unresolved, commentCount: comments)
    }

    public func invalidate() {
        forgeCache.removeAll()
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
