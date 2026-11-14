import Foundation

/// Single source of truth for error code -> (HTTP status, exit code).
public enum ErrorCode: String, Sendable, CaseIterable {
    case invalidRequest = "invalid_request"
    case unsupportedLanguage = "unsupported_language"
    case notInstalled = "not_installed"
    case unableToDetect = "unable_to_detect"
    case payloadTooLarge = "payload_too_large"
    case notFound = "not_found"
    case methodNotAllowed = "method_not_allowed"
    case timeout = "timeout"
    /// CLI only (no HTTP status).
    case sessionUnavailable = "session_unavailable"
    /// CLI only (no HTTP status).
    case invalidConfig = "invalid_config"
    case internalError = "internal"

    public var httpStatus: Int? {
        switch self {
        case .invalidRequest, .unsupportedLanguage, .notInstalled, .unableToDetect: return 400
        case .payloadTooLarge: return 413
        case .notFound: return 404
        case .methodNotAllowed: return 405
        case .timeout: return 504
        case .internalError: return 500
        case .sessionUnavailable, .invalidConfig: return nil
        }
    }

    public var exitCode: ExitCode {
        switch self {
        case .invalidRequest, .payloadTooLarge, .notFound, .methodNotAllowed: return .usage
        case .unsupportedLanguage, .notInstalled: return .unavailable
        case .unableToDetect: return .dataError
        case .timeout, .sessionUnavailable: return .tempFail
        case .invalidConfig: return .config
        case .internalError: return .runtimeError
        }
    }

    /// Map a server response to an exit code: a known `code` wins, otherwise the HTTP status
    /// class decides (4xx -> 64, anything else -> 1).
    public static func exitCode(forCode code: String?, httpStatus: Int) -> ExitCode {
        if let code, let known = ErrorCode(rawValue: code) { return known.exitCode }
        return (400..<500).contains(httpStatus) ? .usage : .runtimeError
    }
}

extension ErrorCode {
    /// Default next action for each code (single table). Call sites that know more pass a specific `fix`.
    public var defaultFix: String {
        switch self {
        case .invalidRequest:
            return "see `maclang <command> --help`; HTTP API: POST /translate {\"q\":\"Hello\",\"source\":\"auto\",\"target\":\"ko\"}"
        case .unsupportedLanguage:
            return "list installed pairs with `maclang languages --from <source>` (HTTP: GET /languages) and use one of the listed codes"
        case .notInstalled:
            return "install the pair in System Settings > General > Language & Region > Translation Languages, or omit --strategy (maclang then requests high fidelity)"
        case .unableToDetect:
            return "pass the language explicitly (`--from <code>`; HTTP: \"source\")"
        case .payloadTooLarge:
            return "split the text into smaller requests, or start the server with a larger `serve --max-body-kib`"
        case .notFound:
            return "use GET /health, POST /translate, POST /detect or GET /languages"
        case .methodNotAllowed:
            return "use the method listed for this path: GET /health, POST /translate, POST /detect, GET /languages"
        case .timeout:
            return "retry; for long texts raise `--timeout` (CLI) or `serve --engine-timeout`; check `maclang service status`"
        case .sessionUnavailable:
            return "log in to this Mac's desktop (a locked screen is fine), then retry; check `maclang doctor` and the server log (logs/server.log under the maclang home)"
        case .invalidConfig:
            return "fix or delete config.json in the maclang home (example: {\"host\":\"127.0.0.1\",\"port\":9091}) or rerun `maclang service install --port <N>`"
        case .internalError:
            return "retry; if it persists, check the server log (logs/server.log under the maclang home) and `maclang doctor`"
        }
    }
}

/// An error carrying a table code, a human-readable message (no request text), a copy-pasteable next
/// action (`fix`, defaulting to the code's table entry) and an optional echo of the offending input.
public struct LangError: Error, Sendable, Equatable {
    public let code: ErrorCode
    public let message: String
    public let fix: String
    public let field: String?
    public let received: String?

    public init(_ code: ErrorCode, _ message: String, fix: String? = nil, field: String? = nil, received: String? = nil) {
        self.code = code
        self.message = message
        self.fix = fix ?? code.defaultFix
        self.field = field
        self.received = received
    }
}
