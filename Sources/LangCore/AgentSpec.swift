import Foundation

public enum AgentSpec {
    /// LaunchAgent plist. The key set is part of the service contract: `LimitLoadToSessionType`
    /// keeps the server inside the GUI login session and `KeepAlive.SuccessfulExit = false`
    /// restarts crashes but not a clean `maclang service stop`.
    public static func plist(paths: Paths) -> Data {
        let log = paths.serverLog.path
        let dict: [String: Any] = [
            "Label": paths.label,
            "ProgramArguments": [paths.bundleExecutable.path, "serve"],
            "LimitLoadToSessionType": "Aqua",
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 10,
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    public struct PrintInfo: Equatable, Sendable {
        public var state: String?
        public var pid: Int?
        public var lastExitCode: Int?
        /// The `program =` line: the executable the agent runs.
        public var program: String?
        public init(state: String?, pid: Int?, lastExitCode: Int?, program: String? = nil) {
            self.program = program
            self.state = state
            self.pid = pid
            self.lastExitCode = lastExitCode
        }
    }

    /// Parse `launchctl print gui/<uid>/<label>`: only attributes indented by exactly one tab
    /// (`state =`, `pid =`, `last exit code =`). Deeper lines belong to nested blocks.
    public static func parsePrint(_ output: String) -> PrintInfo {
        var info = PrintInfo(state: nil, pid: nil, lastExitCode: nil)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let body = line.dropFirst()
            if let v = value(body, "state") {
                if info.state == nil { info.state = v }
            } else if let v = value(body, "pid") {
                if info.pid == nil { info.pid = Int(v) }
            } else if let v = value(body, "program") {
                if info.program == nil { info.program = v }
            } else if let v = value(body, "last exit code") {
                if info.lastExitCode == nil { info.lastExitCode = Int(v) }
            }
        }
        return info
    }

    private static func value(_ line: Substring, _ key: String) -> String? {
        let prefix = key + " = "
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    /// True when the agent's `program =` is exactly this install's bundle executable.
    public static func isOwn(program: String?, expected: String) -> Bool {
        guard let program else { return false }
        func norm(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath().path }
        return norm(program) == norm(expected)
    }

    // MARK: bootstrap handshake (non-GUI install asks the GUI-session app to run launchctl bootstrap)

    public static func encodeBootstrapResult(exit: Int, output: String) -> Data {
        let obj: [String: Any] = ["exit": exit, "output": output]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    public static func decodeBootstrapResult(_ data: Data) -> (exit: Int, output: String)? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let e = o["exit"] as? Int, let out = o["output"] as? String else { return nil }
        return (e, out)
    }
}
