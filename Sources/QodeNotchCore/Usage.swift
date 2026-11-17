import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Plan limits (claude.ai subscription)

public struct UsageLimit: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case session = "session"            // 5-hour window
        case weekly = "weekly_all"          // 7 days, all models
        case weeklyModel = "weekly_scoped"  // 7 days, one model (e.g. Opus)
    }

    public var kind: Kind
    /// 0…100
    public var percent: Double
    public var resetsAt: Date?
    public var modelLabel: String?

    public var id: String { kind.rawValue + (modelLabel ?? "") }

    public var title: String {
        switch kind {
        case .session: return "5-Stunden-Fenster"
        case .weekly: return "Woche (alle Modelle)"
        case .weeklyModel: return "Woche (\(modelLabel ?? "Modell"))"
        }
    }

    public var shortTitle: String {
        switch kind {
        case .session: return "5h"
        case .weekly: return "Woche"
        case .weeklyModel: return modelLabel ?? "Modell"
        }
    }
}

public struct UsageLimits: Equatable, Sendable {
    public var limits: [UsageLimit]
    public var fetchedAt: Date
    public var plan: String?

    /// Parse `GET /api/oauth/usage`. Understands the `limits[]` array and the
    /// older top-level `five_hour` / `seven_day*` objects.
    public static func parse(_ data: Data, plan: String? = nil, now: Date = Date()) -> UsageLimits? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var limits: [UsageLimit] = []
        for item in obj["limits"] as? [[String: Any]] ?? [] {
            guard let kindRaw = item["kind"] as? String, let kind = UsageLimit.Kind(rawValue: kindRaw),
                  let pct = number(item["percent"]) else { continue }
            let model = ((item["scope"] as? [String: Any])?["model"] as? [String: Any])
            limits.append(UsageLimit(kind: kind, percent: pct, resetsAt: date(item["resets_at"]),
                                     modelLabel: (model?["display_name"] as? String) ?? (model?["id"] as? String)))
        }
        if limits.isEmpty {
            func legacy(_ key: String, _ kind: UsageLimit.Kind, _ label: String? = nil) {
                guard let item = obj[key] as? [String: Any], let u = number(item["utilization"]) else { return }
                limits.append(UsageLimit(kind: kind, percent: u, resetsAt: date(item["resets_at"]), modelLabel: label))
            }
            legacy("five_hour", .session)
            legacy("seven_day", .weekly)
            legacy("seven_day_opus", .weeklyModel, "Opus")
            if !limits.contains(where: { $0.kind == .weeklyModel }) { legacy("seven_day_sonnet", .weeklyModel, "Sonnet") }
        }
        guard !limits.isEmpty else { return nil }
        let order = UsageLimit.Kind.allCases
        limits.sort { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
        return UsageLimits(limits: limits, fetchedAt: now, plan: plan)
    }

    static func number(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    static func date(_ any: Any?) -> Date? {
        if let s = any as? String { return TranscriptReader.parseDate(s) }
        if let n = any as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue > 1e12 ? n.doubleValue / 1000 : n.doubleValue) }
        return nil
    }
}

public enum UsageError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case expired
    case rateLimited
    case http(Int)
    case network(String)
    case parse

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Kein Claude-Login gefunden (Keychain oder ~/.claude/.credentials.json)."
        case .expired: return "Login abgelaufen – einmal Claude Code starten, dann wird er erneuert."
        case .rateLimited: return "Zu viele Abfragen – später erneut versuchen."
        case let .http(code): return "Serverfehler (HTTP \(code))."
        case let .network(msg): return "Netzwerkfehler: \(msg)"
        case .parse: return "Antwort konnte nicht gelesen werden."
        }
    }
}

/// Reads Claude Code's OAuth login and asks Anthropic for the plan limits –
/// the same numbers `/usage` shows in Claude Code.
public enum UsageLimitsClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let keychainService = "Claude Code-credentials"

    public struct Credential: Equatable, Sendable {
        public var accessToken: String
        public var expiresAt: Date?
        public var plan: String?

        public var isExpired: Bool { expiresAt.map { $0 < Date() } ?? false }
    }

    public static func parseCredential(_ data: Data) -> Credential? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credential(accessToken: token, expiresAt: expires, plan: oauth["subscriptionType"] as? String)
    }

    /// Native Claude Code keeps the login in the macOS keychain; Claude Code on
    /// Linux – e.g. inside airlock, which mounts ~/.claude – in a JSON file.
    /// The freshest valid one wins.
    public static func loadCredential() -> Credential? {
        var found: [Credential] = []
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/security") {
            let r = Shell.runSync("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"], timeout: 15)
            if r.ok, let c = parseCredential(Data(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) { found.append(c) }
        }
        if let data = FileManager.default.contents(atPath: Paths.claudeDir + "/.credentials.json"), let c = parseCredential(data) {
            found.append(c)
        }
        return found.sorted { ($0.expiresAt ?? .distantFuture) > ($1.expiresAt ?? .distantFuture) }.first { !$0.isExpired } ?? found.first
    }

    public static func fetch() async throws -> UsageLimits {
        let credential = await Task.detached { loadCredential() }.value
        guard let cred = credential else { throw UsageError.notLoggedIn }
        if cred.isExpired { throw UsageError.expired }
        var req = URLRequest(url: endpoint)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(cred.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("QodeNotch", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            guard let limits = UsageLimits.parse(data, plan: cred.plan) else { throw UsageError.parse }
            return limits
        case 401, 403: throw UsageError.expired
        case 429: throw UsageError.rateLimited
        default: throw UsageError.http(status)
        }
    }
}

// MARK: - Local token usage (from transcripts)

public struct DailyUsage: Equatable, Sendable, Identifiable {
    public var day: Date           // start of the local day
    public var byModel: [String: TokenUsage]
    public var id: Date { day }
    public var total: TokenUsage { byModel.values.reduce(TokenUsage(), +) }
}

public struct UsageReport: Equatable, Sendable {
    public var days: [DailyUsage]   // oldest → newest, always `dayCount` entries
    public var today: TokenUsage { days.last?.total ?? TokenUsage() }
    public var total: TokenUsage { days.reduce(TokenUsage()) { $0 + $1.total } }

    public var byModel: [(model: String, usage: TokenUsage)] {
        var m: [String: TokenUsage] = [:]
        for d in days { for (k, v) in d.byModel { m[k, default: TokenUsage()] += v } }
        return m.map { ($0.key, $0.value) }.sorted { $0.usage.total > $1.usage.total }
    }

    public static func == (a: UsageReport, b: UsageReport) -> Bool { a.days == b.days }
}

/// Sums token usage from all transcripts of the last days. Files are read
/// incrementally: only bytes appended since the previous scan are parsed.
public actor LocalUsageScanner {
    public static let shared = LocalUsageScanner()

    private struct FileState {
        var offset: UInt64 = 0
        var converter = ForeignTranscriptConverter()
        var seen = Set<String>()
        var perDay: [Date: [String: TokenUsage]] = [:]
    }

    private var files: [String: FileState] = [:]
    private let calendar = Calendar.current

    public init() {}

    public func report(days dayCount: Int = 7, now: Date = Date()) -> UsageReport {
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) else { return UsageReport(days: []) }
        let fm = FileManager.default
        var aggregate: [Date: [String: TokenUsage]] = [:]
        let projects = (try? fm.contentsOfDirectory(atPath: Paths.claudeProjectsDir)) ?? []
        var alive = Set<String>()
        var paths: [String] = []
        for project in projects where !project.hasPrefix(".") {
            let dir = Paths.claudeProjectsDir + "/" + project
            for e in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where e.hasSuffix(".jsonl") {
                paths.append(dir + "/" + e)
            }
        }
        // Codex (OpenAI) and Copilot CLI sessions count too.
        paths += AgentStores.codexRollouts(days: dayCount + 1, now: now)
        paths += AgentStores.copilotEventFiles()
        for path in paths {
            guard let m = TranscriptReader.mtime(path), m >= first else { continue }
            alive.insert(path)
            let state = scan(path)
            for (day, models) in state.perDay where day >= first {
                for (model, u) in models { aggregate[day, default: [:]][model, default: TokenUsage()] += u }
            }
        }
        files = files.filter { alive.contains($0.key) }

        var days: [DailyUsage] = []
        for i in 0..<dayCount {
            guard let d = calendar.date(byAdding: .day, value: i, to: first) else { continue }
            days.append(DailyUsage(day: d, byModel: aggregate[d] ?? [:]))
        }
        return UsageReport(days: days)
    }

    private func scan(_ path: String) -> FileState {
        var state = files[path] ?? FileState()
        guard let fh = FileHandle(forReadingAtPath: path) else { return state }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() }   // file was rewritten
        guard size > state.offset else { files[path] = state; return state }
        try? fh.seek(toOffset: state.offset)
        let data = fh.readDataToEndOfFile()
        // Only consume complete lines; a partial last line is read next time.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { files[path] = state; return state }
        let complete = data[data.startIndex...lastNewline]
        state.offset += UInt64(complete.count)
        for raw in complete.split(separator: 0x0A) {
            // Cheap pre-filter before JSON parsing.
            guard raw.count > 20, let obj = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any] else { continue }
            let lines = state.converter.convert(obj).map { $0.map(TranscriptLine.init(json:)) } ?? [TranscriptLine(json: obj)]
            for line in lines {
                guard line.type == "assistant", let usage = line.usage, let model = line.model, model != "<synthetic>",
                      let ts = line.timestamp.flatMap(TranscriptReader.parseDate) else { continue }
                if let id = line.messageId, !state.seen.insert(id).inserted { continue }
                let day = calendar.startOfDay(for: ts)
                state.perDay[day, default: [:]][model, default: TokenUsage()] += usage
            }
        }
        files[path] = state
        return state
    }
}

public enum TokenFormat {
    /// 1234 → "1,2 Tsd.", 2_500_000 → "2,5 Mio."
    public static func short(_ n: Int) -> String {
        let d = Double(n)
        func f(_ v: Double) -> String { String(format: v < 10 ? "%.1f" : "%.0f", v).replacingOccurrences(of: ".", with: ",") }
        if d >= 1_000_000_000 { return f(d / 1_000_000_000) + " Mrd." }
        if d >= 1_000_000 { return f(d / 1_000_000) + " Mio." }
        if d >= 1_000 { return f(d / 1_000) + " Tsd." }
        return "\(n)"
    }
}
