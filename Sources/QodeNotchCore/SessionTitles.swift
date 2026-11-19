import Foundation

/// Session titles (`ai-title` / `custom-title` records) from whole transcripts.
/// Claude Code appends them anywhere in the file, so head/tail reads miss them.
/// Files are read incrementally: only bytes added since the last call are parsed.
public actor SessionTitles {
    public static let shared = SessionTitles()

    private struct State {
        var offset: UInt64 = 0
        var lines: [TranscriptLine] = []
    }
    private var files: [String: State] = [:]

    public init() {}

    public func name(transcript path: String, sessionId: String?) -> String? {
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
                    state.lines += TranscriptReader.titleLines(in: Data(complete))
                    // Only the newest few entries matter.
                    if state.lines.count > 40 { state.lines = Array(state.lines.suffix(40)) }
                }
            }
        }
        files[path] = state
        if files.count > 500 { files = files.filter { $0.key == path } }
        return TranscriptReader.sessionName(state.lines, sessionId: sessionId)
    }
}
