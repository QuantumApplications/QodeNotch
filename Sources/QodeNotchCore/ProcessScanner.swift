import Foundation

public struct ProcessEntry: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var cpuPercent: Double
    public var comm: String

    public init(pid: Int32, ppid: Int32, cpuPercent: Double, comm: String) {
        self.pid = pid
        self.ppid = ppid
        self.cpuPercent = cpuPercent
        self.comm = comm
    }

    public var basename: String {
        comm.split(separator: "/").last.map(String.init) ?? comm
    }
}

public typealias ProcessTree = [Int32: ProcessEntry]

/// Process-table helpers built on `ps` and `lsof`.
public enum ProcessScanner {
    /// One `ps` call for the whole table.
    public static func buildTree() async -> ProcessTree {
        let r = await Shell.run("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,comm="], timeout: 5)
        return parseTree(r.stdout)
    }

    public static func parseTree(_ output: String) -> ProcessTree {
        var tree: ProcessTree = [:]
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            let cpu = Double(parts[2].replacingOccurrences(of: ",", with: ".")) ?? 0
            tree[pid] = ProcessEntry(pid: pid, ppid: ppid, cpuPercent: cpu, comm: String(parts[3]).trimmingCharacters(in: .whitespaces))
        }
        return tree
    }

    /// PIDs whose command basename is exactly `claude` (excludes the Claude desktop app).
    public static func claudePids(in tree: ProcessTree) -> [Int32] {
        tree.values.filter { $0.basename == "claude" }.map(\.pid).sorted()
    }

    /// Working directories for many PIDs via one `lsof` call.
    public static func workingDirectories(for pids: [Int32]) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let r = await Shell.run("lsof", ["-a", "-p", pids.map(String.init).joined(separator: ","), "-d", "cwd", "-Fpn"], timeout: 5)
        return parseLsofCwd(r.stdout)
    }

    public static func parseLsofCwd(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var current: Int32?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") {
                current = Int32(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = current {
                result[pid] = String(line.dropFirst())
                current = nil
            }
        }
        return result
    }

    /// TTYs for many PIDs in one `ps` call. Returns normalized `/dev/ttysNNN` paths.
    public static func ttys(for pids: [Int32]) async -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let r = await Shell.run("/bin/ps", ["-o", "pid=,tty=", "-p", pids.map(String.init).joined(separator: ",")], timeout: 5)
        var result: [Int32: String] = [:]
        for raw in r.stdout.split(separator: "\n") {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]) else { continue }
            let tty = String(parts[1])
            if tty != "?" && tty != "??" { result[pid] = normalizeTty(tty) }
        }
        return result
    }

    public static func normalizeTty(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
    }

    /// True only if the PID is alive and is a `claude` process.
    public static func isClaudeProcess(_ pid: Int32) async -> Bool {
        let r = await Shell.run("/bin/ps", ["-o", "comm=", "-p", String(pid)], timeout: 3)
        let comm = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (comm.split(separator: "/").last.map(String.init) ?? comm) == "claude"
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// SIGTERM, wait, then SIGKILL — only for verified claude processes.
    public static func terminateClaude(_ pid: Int32) async {
        guard await isClaudeProcess(pid) else { return }
        kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if isAlive(pid) { kill(pid, SIGKILL) }
    }
}
