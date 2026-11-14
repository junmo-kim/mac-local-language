import Foundation

public enum AgentSpec {
    /// LaunchAgent plist (keys are fixed by the plan).
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
    }

    /// Parse `launchctl print gui/<uid>/<label>`: only attributes indented by exactly one tab
    /// (`state =`, `pid =`, `last exit code =`). Deeper lines belong to nested blocks.
    public static func parsePrint(_ output: String) -> PrintInfo {
        var info = PrintInfo()
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t") else { continue }
            let body = line.dropFirst()
            if let v = value(body, "state") {
                if info.state == nil { info.state = v }
            } else if let v = value(body, "pid") {
                if info.pid == nil { info.pid = Int(v) }
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
}
