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

    /// Agent CLI for a process name, from `ps` comm alone.
    public static func agent(forComm comm: String) -> Agent? {
        // Desktop apps (Codex.app, Claude.app …) are not CLI sessions.
        if comm.contains(".app/") { return nil }
        let base = (comm.split(separator: "/").last.map(String.init) ?? comm).lowercased()
        if base == "claude" { return .claude }
        if base == "codex" || (base.hasPrefix("codex-") && !base.contains("app-server") && !base.contains("mcp")) { return .codex }
        if base == "copilot" { return .copilot }
        return nil
    }

    /// All agent CLI processes: native binaries by name, plus Node-based
    /// installs (`node …/@github/copilot/…`) by their arguments.
    public static func agentPids(in tree: ProcessTree) async -> [Int32: Agent] {
        var result: [Int32: Agent] = [:]
        for e in tree.values { if let a = agent(forComm: e.comm) { result[e.pid] = a } }
        let nodes = tree.values.filter { $0.basename == "node" }.map(\.pid)
        guard !nodes.isEmpty else { return result }
        let r = await Shell.run("/bin/ps", ["-ww", "-o", "pid=,args=", "-p", nodes.map(String.init).joined(separator: ",")], timeout: 5)
        for raw in r.stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]) else { continue }
            let args = line[space...]
            if args.contains("@github/copilot") {
                // The npm launcher may re-spawn itself: keep only the outermost Node process.
                if let parent = tree[pid]?.ppid, result[parent] == .copilot { continue }
                result[pid] = .copilot
            }
        }
        return result
    }

    /// A host-side `podman`/`docker` client attached to a container running Claude Code
    /// (airlock, devcontainers, …). Claude itself runs inside the VM, so this process
    /// stands in for it: it owns the terminal tab and receives keystrokes.
    public struct ContainerClient: Equatable, Sendable {
        public var pid: Int32
        /// Absolute path or name of the runtime CLI (podman/docker).
        public var runtime: String
        public var containerName: String?

        public var isAirlock: Bool { containerName?.hasPrefix("airlock-") ?? false }
    }

    static let containerRuntimes: Set<String> = ["podman", "docker"]

    /// Find container clients running Claude Code.
    public static func containerClients(in tree: ProcessTree) async -> [Int32: ContainerClient] {
        let candidates = tree.values.filter { containerRuntimes.contains($0.basename) }.map(\.pid)
        guard !candidates.isEmpty else { return [:] }
        let r = await Shell.run("/bin/ps", ["-ww", "-o", "pid=,args=", "-p", candidates.map(String.init).joined(separator: ",")], timeout: 5)
        var result: [Int32: ContainerClient] = [:]
        for raw in r.stdout.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]) else { continue }
            let args = String(line[space...]).trimmingCharacters(in: .whitespaces)
            if var client = parseContainerInvocation(args) {
                client.pid = pid
                result[pid] = client
            }
        }
        return result
    }

    /// Recognize `podman run … claude`, `podman start --attach airlock-…` and similar.
    public static func parseContainerInvocation(_ args: String) -> ContainerClient? {
        let tokens = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = tokens.first else { return nil }
        let runtime = first.split(separator: "/").last.map(String.init) ?? first
        guard containerRuntimes.contains(runtime) else { return nil }

        // Subcommand: first non-flag token (skipping a leading "container").
        var i = 1
        while i < tokens.count, tokens[i].hasPrefix("-") { i += 1 }
        guard i < tokens.count else { return nil }
        var sub = tokens[i]
        if sub == "container", i + 1 < tokens.count { i += 1; sub = tokens[i] }
        guard ["run", "start", "attach", "exec"].contains(sub) else { return nil }
        let rest = Array(tokens[(i + 1)...])

        var name: String?
        if sub == "run" {
            for (j, t) in rest.enumerated() {
                if t == "--name", j + 1 < rest.count { name = rest[j + 1]; break }
                if t.hasPrefix("--name=") { name = String(t.dropFirst(7)); break }
            }
        } else {
            // start/attach/exec: the first positional argument is the container.
            var skipNext = false
            for t in rest {
                if skipNext { skipNext = false; continue }
                if t.hasPrefix("-") {
                    // Flags of exec that take a value.
                    if ["-e", "--env", "-u", "--user", "-w", "--workdir", "--detach-keys"].contains(t) { skipNext = true }
                    continue
                }
                name = t
                break
            }
        }
        let runsClaude = rest.contains { $0 == "claude" || $0.hasSuffix("/claude") }
        guard (name?.hasPrefix("airlock-") ?? false) || runsClaude else { return nil }
        // Detached runs have no terminal to talk to.
        if sub == "run" && (rest.contains("-d") || rest.contains("--detach")) { return nil }
        if sub == "start" && !(rest.contains("-a") || rest.contains("--attach") || rest.contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("a") }) {
            return nil
        }
        return ContainerClient(pid: 0, runtime: first, containerName: name)
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
