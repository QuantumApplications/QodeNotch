import Foundation

public struct ShellResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var ok: Bool { exitCode == 0 && !timedOut }
}

public enum ShellError: Error, LocalizedError {
    case failed(command: String, result: ShellResult)

    public var errorDescription: String? {
        switch self {
        case let .failed(command, result):
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.timedOut { return "\(command): Zeitüberschreitung" }
            return msg.isEmpty ? "\(command) beendet mit Code \(result.exitCode)" : msg
        }
    }
}

/// Runs external commands. GUI apps on macOS inherit a minimal PATH, so the
/// user's login-shell PATH is resolved once and used for every subprocess.
public enum Shell {
    private static let envLock = NSLock()
    private static var cachedEnvironment: [String: String]?

    /// Environment with the login-shell PATH plus common tool locations.
    public static var environment: [String: String] {
        envLock.lock()
        defer { envLock.unlock() }
        if let env = cachedEnvironment { return env }
        var env = ProcessInfo.processInfo.environment
        var parts = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        if let shellPath = loginShellPath() {
            for p in shellPath.split(separator: ":").map(String.init) where !parts.contains(p) {
                parts.append(p)
            }
        }
        let extras = [
            Paths.home + "/.local/bin", Paths.home + "/.claude/bin", Paths.home + "/.claude/local",
            Paths.home + "/.bun/bin", Paths.home + "/.npm-global/bin",
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        ]
        for p in extras where !parts.contains(p) { parts.append(p) }
        env["PATH"] = parts.joined(separator: ":")
        // Make git never block on prompts.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        cachedEnvironment = env
        return env
    }

    private static func loginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let marker = "__QODENOTCH_PATH__"
        let r = runSync(shell, ["-ilc", "printf '\(marker)%s\(marker)' \"$PATH\""], environment: ProcessInfo.processInfo.environment, timeout: 5)
        guard r.ok else { return nil }
        let comps = r.stdout.components(separatedBy: marker)
        return comps.count >= 3 ? comps[1] : nil
    }

    /// Locate an executable on the resolved PATH.
    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Run a command asynchronously (off the caller's thread).
    @discardableResult
    public static func run(_ executable: String, _ args: [String] = [], cwd: String? = nil,
                           timeout: TimeInterval = 10, input: String? = nil) async -> ShellResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(executable, args, cwd: cwd, timeout: timeout, input: input))
            }
        }
    }

    /// Run and throw on non-zero exit.
    @discardableResult
    public static func runChecked(_ executable: String, _ args: [String] = [], cwd: String? = nil,
                                  timeout: TimeInterval = 10, input: String? = nil) async throws -> String {
        let r = await run(executable, args, cwd: cwd, timeout: timeout, input: input)
        guard r.ok else { throw ShellError.failed(command: ([executable] + args).joined(separator: " "), result: r) }
        return r.stdout
    }

    /// Fire-and-forget launch of a long-running process (e.g. a terminal app).
    public static func spawnDetached(_ executable: String, _ args: [String], cwd: String? = nil) {
        let p = Process()
        guard let path = resolve(executable) else { return }
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.environment = environment
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
    }

    private static func resolve(_ executable: String) -> String? {
        if executable.hasPrefix("/") { return executable }
        return which(executable)
    }

    public static func runSync(_ executable: String, _ args: [String], cwd: String? = nil,
                               environment env: [String: String]? = nil, timeout: TimeInterval = 10,
                               input: String? = nil) -> ShellResult {
        let process = Process()
        let execPath: String?
        if executable.hasPrefix("/") {
            execPath = executable
        } else if env != nil {
            execPath = "/usr/bin/env"
        } else {
            execPath = which(executable)
        }
        guard let path = execPath else {
            return ShellResult(exitCode: 127, stdout: "", stderr: "\(executable): Befehl nicht gefunden", timedOut: false)
        }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = (path == "/usr/bin/env" && !executable.hasPrefix("/")) ? [executable] + args : args
        process.environment = env ?? environment
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = input != nil ? Pipe() : nil
        process.standardInput = inPipe ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ShellResult(exitCode: 127, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        if let inPipe, let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain both pipes concurrently so a full pipe buffer can never deadlock.
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        var timedOut = false
        let deadline = DispatchTime.now() + timeout
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: deadline) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        _ = group.wait(timeout: .now() + 2)

        return ShellResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            stdout: String(decoding: outBox.get(), as: UTF8.self),
            stderr: String(decoding: errBox.get(), as: UTF8.self),
            timedOut: timedOut
        )
    }

    // MARK: - Escaping helpers

    /// Single-quote a string for POSIX shells.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escape for use inside a double-quoted shell string.
    public static func escapeDouble(_ s: String) -> String {
        var out = ""
        for c in s {
            if c == "\"" || c == "$" || c == "`" || c == "\\" { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

/// Thread-safe holder for pipe output collected on a background queue.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
