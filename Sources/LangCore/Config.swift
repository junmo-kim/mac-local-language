import Foundation

/// `<home>/config.json` — `{"host":"127.0.0.1","port":9091}`.
public struct Config: Equatable, Sendable {
    public var host: String
    public var port: Int

    public static let defaultHost = "127.0.0.1"
    public static let defaultPort = 9091
    public static let `default` = Config(host: defaultHost, port: defaultPort)

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// `nil` data (no file) yields the defaults; unreadable content is `invalid_config`.
    public static func parse(_ data: Data?) throws(LangError) -> Config {
        guard let data else { return .default }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LangError(.invalidConfig, "config.json is not a valid JSON object", fix: "fix or delete config.json in the maclang home (example: {\"host\":\"127.0.0.1\",\"port\":9091}) or rerun `maclang service install --port <N>`")
        }
        var config = Config.default
        if let h = obj["host"] {
            guard let s = h as? String, !s.isEmpty else {
                throw LangError(.invalidConfig, "config.json: host must be a non-empty string", fix: "fix or delete config.json in the maclang home (example: {\"host\":\"127.0.0.1\",\"port\":9091}) or rerun `maclang service install --port <N>`", field: "host", received: "\(h)")
            }
            config.host = s
        }
        if let p = obj["port"] {
            guard let n = p as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  let i = Int(exactly: n), (1...65535).contains(i) else {
                throw LangError(.invalidConfig, "config.json: port must be an integer in 1...65535", fix: "fix or delete config.json in the maclang home (example: {\"host\":\"127.0.0.1\",\"port\":9091}) or rerun `maclang service install --port <N>`", field: "port", received: "\(p)")
            }
            config.port = i
        }
        return config
    }

    public func render() -> String {
        YAMLValue.dict([("host", .string(host)), ("port", .int(port))]).render(as: .json) + "\n"
    }

    /// Host a client should connect to for a server bound to `host`.
    public var clientHost: String {
        switch host {
        case "0.0.0.0", "::", "localhost": return "127.0.0.1"
        default: return host
        }
    }
}

/// Environment-derived runtime switches (injected dictionary for testability).
public struct RuntimeEnv: Sendable {
    public let engine: EngineKind
    public let autostart: Bool
    public let mockDelayMs: Int

    public init(env: [String: String]) {
        engine = EngineKind(env: env)
        autostart = env["MACLANG_AUTOSTART"] != "0"
        if let raw = env["MACLANG_MOCK_DELAY_MS"], let ms = Int(raw), ms > 0 {
            mockDelayMs = ms
        } else {
            mockDelayMs = 0
        }
    }
}

/// `--timeout` / `--engine-timeout` limits: finite and in (0, 86400] seconds.
public enum TimeoutBounds {
    public static let max: Double = 86_400
    public static func isValid(_ seconds: Double) -> Bool {
        seconds.isFinite && seconds > 0 && seconds <= max
    }
}
